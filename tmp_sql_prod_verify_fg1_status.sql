select
  n.id,
  n.delivery_status,
  n.retries_count,
  n.queue_id,
  n.created_at,
  n.queued_at,
  n.pushed_at,
  n.failed_at,
  q.status as queue_status,
  q.attempt_count,
  q.processing_started_at,
  q.sent_at,
  q.failed_at as queue_failed_at,
  q.last_error,
  (select count(*) from public.customer_notification_delivery_logs l where l.notification_id = n.id) as delivery_log_count
from public.customer_notifications n
left join public.queue_customer_fcm q on q.id = n.queue_id
where n.id = '98d43a9b-6790-4caf-a068-1c7add7a1b9c';