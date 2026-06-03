with s as (
  select gs as seq
  from generate_series(1, 50) as gs
), ins as (
  insert into public.customer_notifications (
    customer_user_id,
    title,
    body,
    payload,
    source,
    channel,
    delivery_status
  )
  select
    '8d0ccad4-8ba6-43b5-bc19-7b31e8b8e551',
    'اختبار Burst 50 #' || seq,
    'رسالة ضغط 50/10s رقم ' || seq,
    jsonb_build_object(
      'screen', 'orders',
      'click_action', '/?screen=orders',
      'verify_run', 'prod_verify_burst50_20260519',
      'seq', seq
    ),
    'prod_verify_burst50_20260519',
    'push_customer',
    'queued'
  from s
  returning id, created_at
)
select count(*) as inserted_count, min(created_at) as first_created_at, max(created_at) as last_created_at from ins;
