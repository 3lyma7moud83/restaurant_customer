-- Production fix: customer order-status notifications (accepted/on_the_way/delivered)
-- Scope: restaurant_customer customer pipeline only

-- 1) Defensive cleanup for previously duplicated order-status notifications.
with ranked as (
  select
    id,
    row_number() over (
      partition by customer_user_id, order_id, status_key, source
      order by created_at asc, id asc
    ) as rn
  from public.customer_notifications
  where source = 'orders_status_trigger'
    and order_id is not null
    and status_key in ('accepted', 'on_the_way', 'delivered')
)
delete from public.customer_notifications n
using ranked r
where n.id = r.id
  and r.rn > 1;

-- 2) Idempotency guard at DB level: one notification per (customer, order, status) from status trigger source.
create unique index if not exists customer_notifications_order_status_once_idx
  on public.customer_notifications (customer_user_id, order_id, status_key, source)
  where source = 'orders_status_trigger'
    and order_id is not null
    and status_key in ('accepted', 'on_the_way', 'delivered');

-- 3) Professional Arabic message catalog for required statuses only.
create or replace function public.customer_order_status_arabic_message(
  p_status text
)
returns table (
  normalized_status text,
  title text,
  body text
)
language plpgsql
immutable
as $$
declare
  v_status text := lower(replace(coalesce(trim(p_status), ''), '-', '_'));
begin
  if v_status in ('accepted', 'confirmed') then
    return query
    select
      'accepted'::text,
      'تم قبول طلبك 🍽️'::text,
      'المطعم بدأ تجهيز طلبك الآن.'::text;
    return;
  end if;

  if v_status in ('on_the_way', 'on_theway', 'onway', 'on_way', 'picked_up', 'arrived') then
    return query
    select
      'on_the_way'::text,
      'طلبك في الطريق 🚗'::text,
      'الكابتن متجه إليك الآن، تابع الطلب لحظة بلحظة.'::text;
    return;
  end if;

  if v_status in ('delivered', 'delivered_final', 'delivered_confirmed', 'completed', 'done') then
    return query
    select
      'delivered'::text,
      'تم توصيل الطلب ✅'::text,
      'نتمنى تكون التجربة عجبتك ❤️'::text;
    return;
  end if;
end;
$$;

-- 4) Trigger producer: build required payload and enforce insert idempotency.
create or replace function public.create_customer_notification_from_order_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_row jsonb := to_jsonb(new);
  v_old_row jsonb := to_jsonb(old);
  v_customer_text text;
  v_customer_user_id uuid;
  v_order_text text;
  v_order_id uuid;
  v_status text;
  v_prev_status text;
  v_mapped_status text;
  v_title text;
  v_body text;
begin
  v_status := lower(replace(coalesce(trim(v_new_row ->> 'status'), ''), '-', '_'));
  v_prev_status := lower(replace(coalesce(trim(v_old_row ->> 'status'), ''), '-', '_'));

  if v_status = '' or v_status = v_prev_status then
    return new;
  end if;

  select normalized_status, title, body
  into v_mapped_status, v_title, v_body
  from public.customer_order_status_arabic_message(v_status)
  limit 1;

  if coalesce(v_mapped_status, '') = '' then
    return new;
  end if;

  v_customer_text := coalesce(
    nullif(trim(v_new_row ->> 'customer_id'), ''),
    nullif(trim(v_new_row ->> 'user_id'), '')
  );
  if v_customer_text is null then
    return new;
  end if;

  begin
    v_customer_user_id := v_customer_text::uuid;
  exception
    when others then
      return new;
  end;

  v_order_text := nullif(trim(v_new_row ->> 'id'), '');
  if v_order_text is null then
    return new;
  end if;

  begin
    v_order_id := v_order_text::uuid;
  exception
    when others then
      return new;
  end;

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
    v_mapped_status,
    v_title,
    v_body,
    jsonb_build_object(
      'type', 'order_status',
      'status', v_mapped_status,
      'order_id', v_order_text,
      'click_action', '/orders'
    ),
    'orders_status_trigger',
    'push_customer',
    'queued'
  )
  on conflict do nothing;

  return new;
end;
$$;

revoke all on function public.create_customer_notification_from_order_status() from public;
grant execute on function public.create_customer_notification_from_order_status() to service_role;

-- 5) Ensure trigger is installed on orders.status updates.
do $orders_tr$
begin
  if to_regclass('public.orders') is null then
    raise notice 'public.orders is missing; orders status notification trigger was not created.';
    return;
  end if;

  execute 'drop trigger if exists orders_customer_status_notify_tr on public.orders';
  execute '
    create trigger orders_customer_status_notify_tr
    after update of status on public.orders
    for each row
    when (new.status is distinct from old.status)
    execute function public.create_customer_notification_from_order_status()
  ';
end;
$orders_tr$;

-- 6) Safety: normalize customer dispatch URL away from legacy non-customer endpoints.
update public.customer_fcm_dispatch_config
set
  function_url = replace(
    replace(function_url, '/driver-send-fcm', '/send-fcm'),
    '/process-notifications',
    '/send-fcm'
  ),
  updated_at = timezone('utc', now())
where function_url like '%/driver-send-fcm'
   or function_url like '%/process-notifications';
