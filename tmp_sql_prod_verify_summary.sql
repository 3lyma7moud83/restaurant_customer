with target_notifs as (
  select *
  from public.customer_notifications
  where source like 'prod_verify_final_20260522%'
), target_queue as (
  select q.*
  from public.queue_customer_fcm q
  join target_notifs n on n.queue_id = q.id
)
select 'notif_status' as metric, coalesce(delivery_status,'<null>') as key, count(*)::text as value
from target_notifs
group by delivery_status
union all
select 'queue_status' as metric, coalesce(status,'<null>') as key, count(*)::text as value
from target_queue
group by status
union all
select 'notif_count' as metric, 'total' as key, count(*)::text as value from target_notifs
union all
select 'queue_count' as metric, 'total' as key, count(*)::text as value from target_queue
union all
select 'delivery_logs' as metric, 'total' as key, count(*)::text as value
from public.customer_notification_delivery_logs l
where l.notification_id in (select id from target_notifs)
union all
select 'stuck_processing' as metric, 'older_30s' as key, count(*)::text as value
from target_queue
where status='processing' and coalesce(processing_started_at, updated_at, created_at) < timezone('utc', now()) - interval '30 seconds'
union all
select 'retry_due' as metric, 'eligible_now' as key, count(*)::text as value
from target_queue
where status='retry' and next_retry_at <= timezone('utc', now())
union all
select 'old_pending' as metric, 'older_60s' as key, count(*)::text as value
from target_queue
where status='pending' and created_at < timezone('utc', now()) - interval '60 seconds';