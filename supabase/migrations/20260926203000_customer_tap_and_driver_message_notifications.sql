-- Customer notification mapping and driver-chat delivery.
-- No tables or columns are changed: both producers use the existing
-- customer_notifications -> queue_customer_fcm -> send-fcm pipeline.

create or replace function public.customer_order_status_arabic_message(p_status text)
returns table(normalized_status text, title text, body text)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_status text := lower(replace(coalesce(trim(p_status), ''), '-', '_'));
begin
  if v_status in ('pending', 'pending_cashier') then
    return query select
      'pending'::text,
      'تم استلام طلبك'::text,
      'تم استلام طلبك وجارٍ مراجعته.'::text;
  elsif v_status in ('accepted', 'confirmed') then
    return query select
      'accepted'::text,
      'تم قبول طلبك 🍽️'::text,
      'المطعم بدأ تجهيز طلبك الآن.'::text;
  elsif v_status in ('prepared', 'preparing') then
    return query select
      'prepared'::text,
      'طلبك قيد التجهيز 🍳'::text,
      'المطعم يجهز طلبك الآن.'::text;
  elsif v_status in ('assigned', 'driver_assigned') then
    return query select
      'assigned'::text,
      'تم تعيين مندوب لتوصيل طلبك 🚚'::text,
      'المندوب يستعد لاستلام طلبك.'::text;
  elsif v_status in ('on_the_way', 'on_theway', 'onway', 'on_way', 'picked_up') then
    return query select
      'on_the_way'::text,
      'طلبك في الطريق 🚗'::text,
      'الكابتن متجه إليك الآن، تابع الطلب لحظة بلحظة.'::text;
  elsif v_status = 'arrived' then
    return query select
      'arrived'::text,
      'مندوب التوصيل وصل إليك 📍'::text,
      'يرجى استلام طلبك من المندوب.'::text;
  elsif v_status = 'delivered' then
    return query select
      'delivered'::text,
      'تم تسليم طلبك ✅'::text,
      'تم تسليم الطلب، بانتظار تأكيد استلامك.'::text;
  elsif v_status in ('awaiting_customer_confirmation', 'customer_waiting_confirmation') then
    return query select
      'awaiting_customer_confirmation'::text,
      'تم تسليم طلبك ✅'::text,
      'يرجى تأكيد استلام الطلب لإكمال الطلب.'::text;
  elsif v_status in (
    'completed', 'done', 'delivered_final', 'delivered_confirmed',
    'delivery_confirmed', 'received'
  ) then
    return query select
      'completed'::text,
      'تم إكمال طلبك ✅'::text,
      'تم تأكيد استلام الطلب بنجاح.'::text;
  elsif v_status in ('cancelled', 'canceled', 'rejected') then
    return query select
      'cancelled'::text,
      'تم إلغاء طلبك'::text,
      'تم إلغاء الطلب. يمكنك مراجعة تفاصيل الطلب لمعرفة السبب.'::text;
  end if;
end;
$$;

create or replace function public.notify_customer_on_new_driver_chat_message()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_new jsonb := to_jsonb(new);
  v_order_id uuid := public.try_parse_uuid(v_new ->> 'order_id');
  v_message_id text := nullif(trim(v_new ->> 'id'), '');
  v_sender_id uuid := public.try_parse_uuid(v_new ->> 'sender_id');
  v_driver_id uuid;
  v_customer_id uuid;
  v_deep_link text;
begin
  if v_order_id is null or v_message_id is null or v_sender_id is null then
    return new;
  end if;

  select
    public.try_parse_uuid(to_jsonb(o) ->> 'driver_id'),
    coalesce(
      public.try_parse_uuid(to_jsonb(o) ->> 'customer_id'),
      public.try_parse_uuid(to_jsonb(o) ->> 'customer_user_id'),
      public.try_parse_uuid(to_jsonb(o) ->> 'client_id'),
      public.try_parse_uuid(to_jsonb(o) ->> 'user_id')
    )
  into v_driver_id, v_customer_id
  from public.orders o
  where o.id = v_order_id
  limit 1;

  -- Only a message authored by the assigned driver is customer-facing.
  if v_driver_id is null or v_customer_id is null or v_sender_id <> v_driver_id then
    return new;
  end if;

  v_deep_link := '/?screen=chat&order_id=' || v_order_id::text;
  perform pg_advisory_xact_lock(
    hashtext('customer-driver-chat-message:' || v_message_id)
  );

  if exists (
    select 1
    from public.customer_notifications n
    where n.customer_user_id = v_customer_id
      and n.source = 'order_messages_driver_trigger'
      and n.payload ->> 'message_id' = v_message_id
  ) then
    return new;
  end if;

  insert into public.customer_notifications (
    customer_user_id,
    order_id,
    status_key,
    title,
    body,
    payload,
    source,
    channel,
    delivery_status
  ) values (
    v_customer_id,
    v_order_id,
    'driver_message',
    '💬 رسالة جديدة من مندوب التوصيل',
    'لديك رسالة جديدة بخصوص طلبك.',
    jsonb_build_object(
      'type', 'chat_message',
      'event', 'driver_chat_message',
      'message_id', v_message_id,
      'order_id', v_order_id::text,
      'screen', 'chat',
      'click_action', v_deep_link,
      'deep_link', v_deep_link,
      'dedup_key', 'driver_chat_message:' || v_message_id
    ),
    'order_messages_driver_trigger',
    'messages',
    'queued'
  );

  return new;
end;
$$;

drop trigger if exists order_messages_customer_notification_events
  on public.order_messages;
create trigger order_messages_customer_notification_events
after insert on public.order_messages
for each row execute function public.notify_customer_on_new_driver_chat_message();
