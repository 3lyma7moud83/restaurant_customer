with seed as (
  insert into public.customer_notifications (
    customer_user_id,
    title,
    body,
    payload,
    source,
    channel,
    delivery_status
  )
  values (
    '8d0ccad4-8ba6-43b5-bc19-7b31e8b8e551',
    'اختبار إنتاجي 1',
    'رسالة تحقق إنتاجي فورية',
    '{"screen":"orders","click_action":"/?screen=orders","verify_run":"prod_verify_single_20260519"}'::jsonb,
    'prod_verify_single_20260519',
    'push_customer',
    'queued'
  )
  returning id, created_at
)
select id, created_at from seed;
