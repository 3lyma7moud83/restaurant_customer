with seed as (
  insert into public.customer_notifications (
    customer_user_id,
    title,
    body,
    payload,
    source,
    channel,
    delivery_status
  ) values (
    '8d0ccad4-8ba6-43b5-bc19-7b31e8b8e551',
    'Final Retry Test 1',
    'retry-offline test 2026-05-22',
    '{"screen":"orders","click_action":"/?screen=orders","verify_run":"prod_verify_final_20260522_retry_offline"}'::jsonb,
    'prod_verify_final_20260522_retry_offline',
    'push_customer',
    'queued'
  ) returning id, queue_id, created_at
)
select * from seed;