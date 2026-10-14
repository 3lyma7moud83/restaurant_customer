create or replace function public.notify_manager_order_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_manager_id uuid;
  v_status text := lower(replace(coalesce(trim(new.status), ''), '-', '_'));
  v_type text;
  v_title text;
  v_body text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return new;
  end if;

  select m.user_id into v_manager_id
  from public.managers m
  where m.restaurant_id = new.restaurant_id
  limit 1;
  if v_manager_id is null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_type := 'order_created';
    v_title := 'طلب جديد';
    v_body := 'تم استلام طلب جديد';
  else
    v_type := 'order_status_changed';
    v_title := 'تحديث حالة الطلب';
    v_body := case
      when v_status in ('accepted', 'preparing') then 'تم قبول الطلب وبدأ التحضير'
      when v_status in ('ready', 'prepared', 'ready_for_delivery') then 'الطلب جاهز للتسليم'
      when v_status in ('on_way', 'on_the_way') then 'خرج الطلب للتوصيل'
      when v_status = 'delivered' then 'تم تسليم الطلب للعميل'
      when v_status in ('awaiting_customer_confirmation', 'customer_waiting_confirmation') then 'بانتظار تأكيد العميل للاستلام'
      when v_status = 'completed' then 'اكتمل الطلب بنجاح'
      when v_status in ('cancelled', 'canceled', 'rejected') then 'تم إلغاء الطلب'
      else 'تم تحديث حالة الطلب'
    end;
  end if;

  perform pg_advisory_xact_lock(hashtext(
    'manager:order:' || new.id::text || ':' || v_manager_id::text || ':' || v_type || ':' || v_status
  ));
  if exists (
    select 1 from public.manager_notifications mn
    where mn.manager_id = v_manager_id
      and mn.type = v_type
      and mn.data ->> 'order_id' = new.id::text
      and coalesce(mn.data ->> 'status', '') = v_status
  ) then
    return new;
  end if;

  perform public.create_manager_notification(
    v_manager_id,
    v_title,
    v_body,
    v_type,
    jsonb_build_object(
      'order_id', new.id,
      'restaurant_id', new.restaurant_id,
      'status', v_status,
      'previous_status', case when tg_op = 'UPDATE' then old.status else null end,
      'screen', 'orders',
      'click_action', '/?screen=order_tracking&order_id=' || new.id::text
    )
  );
  return new;
end;
$$;
