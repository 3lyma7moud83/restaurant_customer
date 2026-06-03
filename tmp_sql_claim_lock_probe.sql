with a as (
  select id from public.claim_customer_fcm_queue(null, 5, 'prod_verify_lock_a_20260522')
), b as (
  select id from public.claim_customer_fcm_queue(null, 5, 'prod_verify_lock_b_20260522')
)
select
  (select count(*) from a) as a_count,
  (select count(*) from b) as b_count,
  (select count(*) from (select id from a intersect select id from b) x) as overlap_count,
  (select json_agg(id order by id) from a) as a_ids,
  (select json_agg(id order by id) from b) as b_ids;