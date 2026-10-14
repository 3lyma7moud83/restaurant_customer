-- These operational views contain cross-user delivery metadata and token
-- health. They are backend-only and must never be exposed through Data API.
do $$
declare
  v_view text;
begin
  foreach v_view in array array[
    'notification_token_health',
    'notification_queue_observability',
    'notification_delivery_observability',
    'notification_token_health_observability',
    'worker_queue_pressure'
  ] loop
    if to_regclass('public.' || v_view) is not null then
      execute format('alter view public.%I set (security_invoker = true)', v_view);
      execute format('revoke all on public.%I from anon, authenticated', v_view);
      execute format('grant select on public.%I to service_role', v_view);
    end if;
  end loop;
end;
$$;
