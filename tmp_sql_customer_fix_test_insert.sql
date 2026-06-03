with vars as (
  select 'codex_customer_fix_test_20260524_a'::text as marker, '463cd0e2-5b86-4c31-9ea6-fe5d443ec88c'::uuid as customer_id
), inserted as (
  insert into public.customer_notifications (
    customer_user_id,
    order_id,
    status_key,
    title,
    body,
    payload,
    source,
    channel
  )
  select v.customer_id, gen_random_uuid(), x.status_key, x.title, x.body,
         jsonb_build_object('marker', v.marker, 'event', x.status_key, 'screen', 'orders', 'click_action', '/?screen=orders', 'sound', 'default'),
         'codex_fix_test',
         'push_customer'
  from vars v
  cross join (
    values
      ('accepted', 'Order Accepted (Fix Test)', 'Order accepted notification test.'),
      ('on_the_way', 'On The Way (Fix Test)', 'Order on-the-way notification test.'),
      ('delivered', 'Delivered (Fix Test)', 'Order delivered notification test.')
  ) as x(status_key, title, body)
  returning id, status_key, created_at
)
select i.id as notification_id, i.status_key, cn.queue_id, q.status as queue_status, cn.delivery_status, cn.created_at
from inserted i
join public.customer_notifications cn on cn.id = i.id
left join public.queue_customer_fcm q on q.id = cn.queue_id
order by cn.created_at;