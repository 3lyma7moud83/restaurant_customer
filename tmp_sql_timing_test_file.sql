insert into public.customer_notifications (customer_user_id,title,body,payload,source,channel,delivery_status)
values ('8d0ccad4-8ba6-43b5-bc19-7b31e8b8e551','timing test 1','t1','{"verify":"timing_test_file"}'::jsonb,'timing_test_file','push_customer','queued');
select pg_sleep(1);
insert into public.customer_notifications (customer_user_id,title,body,payload,source,channel,delivery_status)
values ('8d0ccad4-8ba6-43b5-bc19-7b31e8b8e551','timing test 2','t2','{"verify":"timing_test_file"}'::jsonb,'timing_test_file','push_customer','queued');
select pg_sleep(1);
insert into public.customer_notifications (customer_user_id,title,body,payload,source,channel,delivery_status)
values ('8d0ccad4-8ba6-43b5-bc19-7b31e8b8e551','timing test 3','t3','{"verify":"timing_test_file"}'::jsonb,'timing_test_file','push_customer','queued');
select min(created_at) as min_created, max(created_at) as max_created, extract(epoch from max(created_at)-min(created_at)) as spread
from public.customer_notifications where source='timing_test_file' and created_at >= timezone('utc', now()) - interval '10 minutes';