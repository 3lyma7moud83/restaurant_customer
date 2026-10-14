-- Route manager dispatch through the existing authenticated database dispatcher.
-- The previous cron body sent an unauthorised batch request directly to send-fcm.
select cron.unschedule(jobid)
from cron.job
where jobname = 'manager-notifications-dispatch';

select cron.schedule(
  'manager-notifications-dispatch',
  '* * * * *',
  $$select public.invoke_role_fcm_dispatch('manager', null, 80, true);$$
);
