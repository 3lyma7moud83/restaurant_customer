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
    'Final Verify FG 1',
    'foreground live test 2026-05-22T19:18',
    '{"screen":"orders","click_action":"/?screen=orders","verify_run":"prod_verify_final_20260522_fg1"}'::jsonb,
    'prod_verify_final_20260522_fg1',
    'push_customer',
    'queued'
  )
  returning id, created_at
)
select id, created_at from seed;