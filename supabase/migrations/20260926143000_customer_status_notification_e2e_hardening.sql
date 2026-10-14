-- Customer order-status push pipeline hardening.
--
-- One source of truth: orders -> customer_notifications -> queue_customer_fcm
-- -> send-fcm(target=customer).  The transition key makes producer retries
-- idempotent without suppressing a genuine later transition back to a status.

create or replace function public.customer_order_status_arabic_message(p_status text)
returns table(normalized_status text, title text, body text)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_status text := lower(replace(coalesce(trim(p_status), ''), '-', '_'));
begin
  if v_status in ('pending', 'pending_cashier') then
    return query select
      'pending'::text,
      'تم استلام طلبك'::text,
      'تم استلام طلبك وجارٍ مراجعته.'::text;
  elsif v_status in ('accepted', 'confirmed') then
    return query select
      'accepted'::text,
      'تم قبول طلبك 🍽️'::text,
      'المطعم بدأ تجهيز طلبك الآن.'::text;
  elsif v_status in ('prepared', 'preparing') then
    return query select
      'prepared'::text,
      'طلبك قيد التجهيز 🍳'::text,
      'المطعم يجهز طلبك الآن.'::text;
  elsif v_status in ('ready', 'ready_for_delivery') then
    return query select
      'ready'::text,
      'طلبك أصبح جاهزًا ✅'::text,
      'طلبك جاهز للتوصيل.'::text;
  elsif v_status in ('assigned', 'driver_assigned') then
    return query select
      'assigned'::text,
      'تم تعيين مندوب لتوصيل طلبك 🚚'::text,
      'المندوب يستعد لاستلام طلبك.'::text;
  elsif v_status in ('on_the_way', 'on_theway', 'onway', 'on_way', 'picked_up') then
    return query select
      'on_the_way'::text,
      'طلبك في الطريق 🚗'::text,
      'الكابتن متجه إليك الآن، تابع الطلب لحظة بلحظة.'::text;
  elsif v_status = 'arrived' then
    return query select
      'arrived'::text,
      'مندوب التوصيل وصل إليك 📍'::text,
      'يرجى استلام طلبك من المندوب.'::text;
  elsif v_status = 'delivered' then
    return query select
      'delivered'::text,
      'تم تسليم طلبك ✅'::text,
      'تم تسليم الطلب، بانتظار تأكيد استلامك.'::text;
  elsif v_status in ('awaiting_customer_confirmation', 'customer_waiting_confirmation') then
    return query select
      'awaiting_customer_confirmation'::text,
      'تم تسليم طلبك ✅'::text,
      'يرجى تأكيد استلام الطلب لإكمال الطلب.'::text;
  elsif v_status in (
    'completed', 'done', 'delivered_final', 'delivered_confirmed',
    'delivery_confirmed', 'received'
  ) then
    return query select
      'completed'::text,
      'تم إكمال طلبك ✅'::text,
      'تم تأكيد استلام الطلب بنجاح.'::text;
  elsif v_status in ('cancelled', 'canceled', 'rejected') then
    return query select
      'cancelled'::text,
      'تم إلغاء طلبك'::text,
      'تم إلغاء الطلب. يمكنك مراجعة تفاصيل الطلب لمعرفة السبب.'::text;
  end if;
end;
$$;

create or replace function public.create_customer_notification_from_order_status()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_new_row jsonb := to_jsonb(new);
  v_old_row jsonb := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
  v_customer_text text;
  v_customer_user_id uuid;
  v_order_text text;
  v_order_id uuid;
  v_status text;
  v_previous_status text;
  v_normalized_status text;
  v_title text;
  v_body text;
  v_transition_version text;
  v_transition_key text;
  v_deep_link text;
begin
  v_status := lower(replace(coalesce(trim(v_new_row ->> 'status'), ''), '-', '_'));
  v_previous_status := lower(replace(coalesce(trim(v_old_row ->> 'status'), ''), '-', '_'));

  if v_status = '' or (tg_op = 'UPDATE' and v_status = v_previous_status) then
    return new;
  end if;

  select normalized_status, title, body
  into v_normalized_status, v_title, v_body
  from public.customer_order_status_arabic_message(v_status)
  limit 1;

  if coalesce(v_normalized_status, '') = '' then
    return new;
  end if;

  v_customer_text := coalesce(
    nullif(trim(v_new_row ->> 'customer_id'), ''),
    nullif(trim(v_new_row ->> 'user_id'), '')
  );
  v_order_text := nullif(trim(v_new_row ->> 'id'), '');
  if v_customer_text is null or v_order_text is null then
    return new;
  end if;

  begin
    v_customer_user_id := v_customer_text::uuid;
    v_order_id := v_order_text::uuid;
  exception when others then
    return new;
  end;

  v_transition_version := coalesce(
    nullif(trim(v_new_row ->> 'authoritative_state_version'), ''),
    nullif(trim(v_new_row ->> 'order_version'), ''),
    nullif(trim(v_new_row ->> 'logical_version'), ''),
    nullif(trim(v_new_row ->> 'sequence_number'), ''),
    '0'
  );
  v_transition_key := concat_ws(
    ':',
    v_order_text,
    coalesce(nullif(v_previous_status, ''), 'insert'),
    v_status,
    v_transition_version
  );
  v_deep_link := '/?screen=order_tracking&order_id=' || v_order_text;

  -- Serializes concurrent producer executions for this one logical transition.
  perform pg_advisory_xact_lock(hashtext('customer-order-transition:' || v_transition_key));

  if exists (
    select 1
    from public.customer_notifications n
    where n.customer_user_id = v_customer_user_id
      and n.order_id = v_order_id
      and n.source = 'orders_status_trigger'
      and n.payload ->> 'transition_key' = v_transition_key
  ) then
    return new;
  end if;

  insert into public.customer_notifications (
    customer_user_id,
    order_id,
    status_key,
    title,
    body,
    payload,
    source,
    channel,
    delivery_status
  )
  values (
    v_customer_user_id,
    v_order_id,
    v_normalized_status,
    v_title,
    v_body,
    jsonb_build_object(
      'type', 'order_status',
      'event', 'order_status_changed',
      'status', v_normalized_status,
      'original_status', v_status,
      'previous_status', case when tg_op = 'INSERT' then null else v_previous_status end,
      'order_id', v_order_text,
      'screen', 'order_tracking',
      'click_action', v_deep_link,
      'deep_link', v_deep_link,
      'transition_key', v_transition_key
    ),
    'orders_status_trigger',
    'push_customer',
    'queued'
  )
  on conflict do nothing;

  return new;
end;
$$;

-- A single status transition may only create one backend notification.  Old
-- rows do not have transition_key and therefore stay untouched by this index.
drop index if exists public.customer_notifications_order_status_once_idx;
create unique index customer_notifications_order_transition_once_idx
  on public.customer_notifications (
    customer_user_id,
    order_id,
    ((payload ->> 'transition_key'))
  )
  where source = 'orders_status_trigger'
    and order_id is not null
    and payload ? 'transition_key';

create or replace function public.enqueue_customer_fcm()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_queue_id bigint;
  v_config public.customer_fcm_dispatch_config%rowtype;
  v_headers jsonb := jsonb_build_object('Content-Type', 'application/json');
  v_auth_token text;
  v_body jsonb;
begin
  -- Idempotent even if this trigger function is deliberately replayed.
  perform pg_advisory_xact_lock(hashtext('customer-fcm-queue:' || new.id::text));

  select q.id into v_queue_id
  from public.queue_customer_fcm q
  where q.notification_id = new.id
  order by q.id
  limit 1;

  if v_queue_id is null then
    insert into public.queue_customer_fcm (
      notification_id,
      customer_user_id,
      status,
      next_retry_at,
      request_payload
    )
    values (
      new.id,
      new.customer_user_id,
      'pending',
      timezone('utc', now()),
      coalesce(new.payload, '{}'::jsonb)
    )
    returning id into v_queue_id;
  end if;

  update public.customer_notifications
  set
    queue_id = v_queue_id,
    queued_at = timezone('utc', now()),
    delivery_status = 'queued',
    retries_count = 0,
    last_error = null,
    updated_at = timezone('utc', now())
  where id = new.id;

  select * into v_config
  from public.customer_fcm_dispatch_config
  where coalesce(is_enabled, true) = true
  limit 1;

  if coalesce(nullif(trim(v_config.function_url), ''), '') = '' then
    return new;
  end if;

  v_auth_token := nullif(trim(coalesce(v_config.function_auth_token, '')), '');
  if v_auth_token is not null then
    v_headers := v_headers || jsonb_build_object(
      'Authorization',
      'Bearer ' || v_auth_token
    );
  end if;

  v_body := jsonb_build_object(
    'process_single_queue_id', v_queue_id,
    'target', 'customer'
  );

  begin
    perform net.http_post(
      url := v_config.function_url,
      headers := v_headers,
      body := v_body
    );
  exception
    when undefined_function then
      raise warning 'net.http_post is unavailable while enqueuing queue_customer_fcm %', v_queue_id;
    when others then
      raise warning 'enqueue_customer_fcm invoke failed for queue_id %: %', v_queue_id, sqlerrm;
  end;

  return new;
end;
$$;

drop trigger if exists orders_customer_status_notify_tr on public.orders;
drop trigger if exists orders_customer_status_notify_insert_tr on public.orders;

create trigger orders_customer_status_notify_insert_tr
after insert on public.orders
for each row
execute function public.create_customer_notification_from_order_status();

create trigger orders_customer_status_notify_tr
after update of status on public.orders
for each row
when (new.status is distinct from old.status)
execute function public.create_customer_notification_from_order_status();
