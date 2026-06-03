with target as (
  select n.id, n.source, n.created_at, n.queued_at, n.pushed_at, n.queue_id,
         q.processing_started_at, q.sent_at, q.status
  from public.customer_notifications n
  left join public.queue_customer_fcm q on q.id = n.queue_id
  where n.source like 'prod_verify_final_20260522%'
), metrics as (
  select
    extract(epoch from (queued_at - created_at))*1000 as db_to_queue_ms,
    case when processing_started_at is not null then extract(epoch from (processing_started_at - created_at))*1000 end as queue_to_invoke_ms,
    case when sent_at is not null and processing_started_at is not null then extract(epoch from (sent_at - processing_started_at))*1000 end as invoke_to_fcm_ms,
    case when pushed_at is not null then extract(epoch from (pushed_at - created_at))*1000 end as full_e2e_ms
  from target
)
select
  count(*) as total_notifications,
  count(db_to_queue_ms) as db_to_queue_samples,
  percentile_cont(0.5) within group (order by db_to_queue_ms) as db_to_queue_p50,
  percentile_cont(0.95) within group (order by db_to_queue_ms) as db_to_queue_p95,
  count(queue_to_invoke_ms) as queue_to_invoke_samples,
  percentile_cont(0.5) within group (order by queue_to_invoke_ms) as queue_to_invoke_p50,
  percentile_cont(0.95) within group (order by queue_to_invoke_ms) as queue_to_invoke_p95,
  count(invoke_to_fcm_ms) as invoke_to_fcm_samples,
  count(full_e2e_ms) as full_e2e_samples,
  percentile_cont(0.5) within group (order by full_e2e_ms) as full_e2e_p50,
  percentile_cont(0.95) within group (order by full_e2e_ms) as full_e2e_p95
from metrics;