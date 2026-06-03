select
  n.id,
  n.delivery_status,
  n.retries_count,
  n.queue_id,
  n.created_at,
  n.queued_at,
  n.pushed_at,
  n.failed_at,
  n.last_error,
  q.status as queue_status,
  q.attempt_count,
  q.processing_started_at,
  q.sent_at,
  q.failed_at as queue_failed_at,
  q.last_error as queue_last_error,
  (
    select count(*)
    from public.customer_notification_delivery_logs l
    where l.notification_id = n.id
  ) as delivery_log_count
from public.customer_notifications n
left join public.queue_customer_fcm q on q.id = n.queue_id
where n.id = 'fb6586ed-3138-40c4-b7ec-5fcd36d3a2f2';
