do $$
declare
  i integer;
begin
  for i in 1..50 loop
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
      'اختبار Burst 50 paced #' || i,
      'رسالة ضغط 50/10s رقم ' || i,
      jsonb_build_object(
        'screen', 'orders',
        'click_action', '/?screen=orders',
        'verify_run', 'prod_verify_burst50_paced_20260519',
        'seq', i
      ),
      'prod_verify_burst50_paced_20260519',
      'push_customer',
      'queued'
    );

    if (i % 5 = 0) and (i < 50) then
      perform pg_sleep(1);
    end if;
  end loop;
end;
$$;

select
  count(*) as inserted_count,
  min(created_at) as first_created_at,
  max(created_at) as last_created_at,
  extract(epoch from (max(created_at) - min(created_at))) as spread_seconds
from public.customer_notifications
where source = 'prod_verify_burst50_paced_20260519';
