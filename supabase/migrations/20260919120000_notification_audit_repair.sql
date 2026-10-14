-- Notification audit repair: expire unsafe historical backlog, restore retry
-- dispatch for active pipelines, and make order event producers idempotent.

update public.notifications
set status = 'failed',
    retries_count = greatest(retries_count, 3),
    attempts = greatest(attempts, max_attempts),
    error_message = 'stale_notification_expired_by_audit',
    last_error_code = 'STALE_EXPIRED',
    last_error_message = 'Historical notification expired; it must not be delivered out of order.',
    next_retry_at = timezone('utc', now()),
    next_attempt_at = timezone('utc', now()),
    updated_at = timezone('utc', now())
where status in ('pending', 'claimed', 'processing')
  and created_at < timezone('utc', now()) - interval '24 hours';

update public.queue_admin_fcm
set status = 'failed',
    attempt_count = greatest(attempt_count, 6),
    last_error = 'stale_notification_expired_by_audit',
    last_attempt_at = timezone('utc', now()),
    next_retry_at = timezone('utc', now()),
    updated_at = timezone('utc', now())
where status in ('pending', 'processing')
  and created_at < timezone('utc', now()) - interval '24 hours';

update public.queue_cashier_fcm
set status = 'failed',
    attempts = greatest(attempts, max_attempts),
    last_error = 'stale_notification_expired_by_audit',
    processed_at = timezone('utc', now()),
    processing_started_at = null,
    next_retry_at = timezone('utc', now()),
    updated_at = timezone('utc', now())
where status in ('pending', 'retry', 'processing')
  and created_at < timezone('utc', now()) - interval '24 hours';

update public.queue_manager_fcm
set status = 'failed',
    attempts = greatest(attempts, max_attempts),
    last_error = 'stale_notification_expired_by_audit',
    failed_at = timezone('utc', now()),
    processing_started_at = null,
    processor_id = null,
    next_retry_at = timezone('utc', now()),
    updated_at = timezone('utc', now())
where status in ('pending', 'retry', 'processing')
  and created_at < timezone('utc', now()) - interval '24 hours';

update public.queue_driver_fcm
set status = 'dead',
    attempts = greatest(attempts, max_attempts),
    last_error = 'stale_notification_expired_by_audit',
    dead_reason = 'stale_notification_expired_by_audit',
    processing_started_at = null,
    processor_id = null,
    next_retry_at = timezone('utc', now()),
    updated_at = timezone('utc', now())
where status in ('pending', 'retry', 'processing')
  and created_at < timezone('utc', now()) - interval '24 hours';

-- queue_fcm is an abandoned second producer. The authoritative generic
-- dispatcher is notifications_dispatch_processor_tr/process-notifications.
drop trigger if exists trg_enqueue_queue_fcm_from_notifications
  on public.notifications;

create or replace function public.create_manager_notification(
  p_manager_id uuid,
  p_title text,
  p_body text,
  p_type text,
  p_data jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_manager_id is null then
    raise exception 'p_manager_id is required' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.managers m where m.user_id = p_manager_id
  ) then
    raise exception 'manager_not_found' using errcode = '23503';
  end if;
  insert into public.manager_notifications (manager_id, title, body, type, data)
  values (
    p_manager_id,
    coalesce(nullif(btrim(p_title), ''), 'إشعار'),
    coalesce(nullif(btrim(p_body), ''), 'لديك تحديث جديد'),
    coalesce(nullif(btrim(p_type), ''), 'general'),
    coalesce(p_data, '{}'::jsonb)
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.notify_manager_order_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_manager_id uuid;
  v_status text := lower(replace(coalesce(trim(new.status), ''), '-', '_'));
  v_type text;
  v_title text;
  v_body text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
  select m.user_id into v_manager_id from public.managers m
  where m.restaurant_id = new.restaurant_id limit 1;
  if v_manager_id is null then return new; end if;

  if tg_op = 'INSERT' then
    v_type := 'order_created'; v_title := 'طلب جديد'; v_body := 'تم استلام طلب جديد';
  else
    v_type := 'order_status_changed'; v_title := 'تحديث حالة الطلب';
    v_body := case
      when v_status in ('accepted','preparing') then 'تم قبول الطلب وبدأ التحضير'
      when v_status in ('ready','prepared','ready_for_delivery') then 'الطلب جاهز للتسليم'
      when v_status in ('on_way','on_the_way','delivered') then 'خرج الطلب للتوصيل'
      when v_status in ('awaiting_customer_confirmation','customer_waiting_confirmation') then 'بانتظار تأكيد العميل للاستلام'
      when v_status = 'completed' then 'اكتمل الطلب بنجاح'
      when v_status in ('cancelled','canceled','rejected') then 'تم إلغاء الطلب'
      else 'تم تحديث حالة الطلب'
    end;
  end if;

  perform pg_advisory_xact_lock(hashtext(
    'manager:order:' || new.id::text || ':' || v_manager_id::text || ':' || v_type || ':' || v_status
  ));
  if exists (
    select 1 from public.manager_notifications mn
    where mn.manager_id = v_manager_id and mn.type = v_type
      and mn.data ->> 'order_id' = new.id::text
      and coalesce(mn.data ->> 'status', '') = v_status
  ) then return new; end if;

  perform public.create_manager_notification(
    v_manager_id, v_title, v_body, v_type,
    jsonb_build_object('order_id',new.id,'restaurant_id',new.restaurant_id,
      'status',v_status,'previous_status',case when tg_op='UPDATE' then old.status else null end,
      'screen','orders','click_action','/?screen=order_tracking&order_id=' || new.id::text)
  );
  return new;
end;
$$;

-- Retry only fresh rows. Historical rows above are terminal and cannot be
-- replayed out of order after a device reconnects.
select cron.unschedule(jobid)
from cron.job
where jobname in ('generic-notifications-dispatch-audit','admin-fcm-dispatch-audit');

select cron.schedule(
  'generic-notifications-dispatch-audit', '* * * * *',
  $$select public.invoke_generic_notification_processor(null);$$
);
select cron.schedule(
  'admin-fcm-dispatch-audit', '* * * * *',
  $$select public.invoke_role_fcm_dispatch('admin', null, 50, true);$$
);
