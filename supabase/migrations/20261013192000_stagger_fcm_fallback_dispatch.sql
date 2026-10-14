-- Spread the existing fallback dispatchers across alternating minutes.
--
-- The queue tables and retry semantics are unchanged.  Fresh customer events
-- still invoke their single-row dispatcher immediately; these cron entries are
-- the durable fallback.  Before this migration, six cron jobs could start in
-- the same minute and repeatedly hit pg_cron startup timeouts together.
--
-- The manager job is also returned to the authenticated dispatcher already
-- used for role queues.  Its old direct net.http_post body had drifted from
-- the supported dispatcher contract.

select cron.unschedule(jobid)
from cron.job
where jobname in (
  'customer_fcm_retry_fallback_every_minute',
  'driver_fcm_fallback_tick',
  'cashier-fcm-fresh-retry-dispatch',
  'generic-notifications-dispatch-audit',
  'admin-fcm-dispatch-audit',
  'manager-notifications-dispatch'
);

-- Even minutes: customer delivery fallback plus two role queues.
select cron.schedule(
  'customer_fcm_retry_fallback_every_minute',
  '*/2 * * * *',
  $$select public.invoke_customer_fcm_retry_fallback(50);$$
);
select cron.schedule(
  'cashier-fcm-fresh-retry-dispatch',
  '*/2 * * * *',
  $$select public.invoke_cashier_fcm_retry_fallback(50);$$
);
select cron.schedule(
  'admin-fcm-dispatch-audit',
  '*/2 * * * *',
  $$select public.invoke_role_fcm_dispatch('admin', null, 50, true);$$
);

-- Odd minutes: remaining independent fallback workers.
select cron.schedule(
  'driver_fcm_fallback_tick',
  '1-59/2 * * * *',
  $$select public.dispatch_driver_fcm_fallback_tick();$$
);
select cron.schedule(
  'generic-notifications-dispatch-audit',
  '1-59/2 * * * *',
  $$select public.invoke_generic_notification_processor(null);$$
);
select cron.schedule(
  'manager-notifications-dispatch',
  '1-59/2 * * * *',
  $$select public.invoke_role_fcm_dispatch('manager', null, 80, true);$$
);
