do $delivery_confirmation_orders$
begin
  if to_regclass('public.orders') is not null then
    execute 'alter table public.orders
      add column if not exists authoritative_state_version bigint not null default 0,
      add column if not exists order_version bigint not null default 0';
  end if;
end;
$delivery_confirmation_orders$;

create table if not exists public.customer_delivery_issues (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null,
  customer_user_id uuid not null references auth.users(id) on delete cascade,
  reason text not null,
  order_status text not null default 'awaiting_customer_confirmation',
  authoritative_state_version bigint,
  order_version bigint,
  status text not null default 'pending'
    check (status in ('pending', 'in_review', 'resolved', 'rejected')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint customer_delivery_issues_reason_not_blank_chk
    check (length(trim(reason)) > 0)
);

create index if not exists customer_delivery_issues_customer_created_idx
  on public.customer_delivery_issues (customer_user_id, created_at desc);

create index if not exists customer_delivery_issues_order_created_idx
  on public.customer_delivery_issues (order_id, created_at desc);

create index if not exists customer_delivery_issues_status_created_idx
  on public.customer_delivery_issues (status, created_at desc);

drop trigger if exists customer_delivery_issues_set_updated_at
  on public.customer_delivery_issues;
create trigger customer_delivery_issues_set_updated_at
before update on public.customer_delivery_issues
for each row
execute function public.set_updated_at();

alter table public.customer_delivery_issues enable row level security;

drop policy if exists "customer_delivery_issues_select_own"
  on public.customer_delivery_issues;
create policy "customer_delivery_issues_select_own"
on public.customer_delivery_issues
for select
to authenticated
using (auth.uid() = customer_user_id);

drop policy if exists "customer_delivery_issues_insert_own"
  on public.customer_delivery_issues;
create policy "customer_delivery_issues_insert_own"
on public.customer_delivery_issues
for insert
to authenticated
with check (auth.uid() = customer_user_id);

create or replace function public.confirm_delivery_received(
  p_order_id uuid,
  p_authoritative_state_version bigint default null,
  p_order_version bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_order public.orders%rowtype;
  v_order_json jsonb;
  v_owner_text text;
  v_owner_id uuid;
  v_status text;
begin
  if v_user_id is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select *
  into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'order_not_found' using errcode = 'P0002';
  end if;

  v_order_json := to_jsonb(v_order);
  v_owner_text := coalesce(
    nullif(trim(v_order_json ->> 'customer_id'), ''),
    nullif(trim(v_order_json ->> 'user_id'), '')
  );

  if v_owner_text is null then
    raise exception 'order_owner_missing' using errcode = '42501';
  end if;

  begin
    v_owner_id := v_owner_text::uuid;
  exception
    when others then
      raise exception 'order_owner_invalid' using errcode = '42501';
  end;

  if v_owner_id <> v_user_id then
    raise exception 'order_forbidden' using errcode = '42501';
  end if;

  v_status := lower(replace(coalesce(trim(v_order_json ->> 'status'), ''), '-', '_'));
  if v_status <> 'awaiting_customer_confirmation' then
    raise exception 'invalid_order_state:%', v_status using errcode = '22023';
  end if;

  if p_authoritative_state_version is not null
      and coalesce(v_order.authoritative_state_version, 0) <> p_authoritative_state_version then
    raise exception 'stale_order_state' using errcode = '40001';
  end if;

  if p_order_version is not null
      and coalesce(v_order.order_version, 0) <> p_order_version then
    raise exception 'stale_order_state' using errcode = '40001';
  end if;

  update public.orders
  set
    status = 'completed',
    authoritative_state_version = coalesce(authoritative_state_version, 0) + 1,
    order_version = coalesce(order_version, 0) + 1
  where id = p_order_id
  returning * into v_order;

  return jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'status', 'completed',
    'authoritative_state_version', v_order.authoritative_state_version,
    'order_version', v_order.order_version
  );
end;
$$;

revoke all on function public.confirm_delivery_received(uuid, bigint, bigint)
  from public;
grant execute on function public.confirm_delivery_received(uuid, bigint, bigint)
  to authenticated;

create or replace function public.report_delivery_issue(
  p_order_id uuid,
  p_reason text,
  p_authoritative_state_version bigint default null,
  p_order_version bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_reason text := nullif(trim(p_reason), '');
  v_order public.orders%rowtype;
  v_order_json jsonb;
  v_owner_text text;
  v_owner_id uuid;
  v_status text;
  v_issue_id uuid;
begin
  if v_user_id is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if v_reason is null then
    raise exception 'delivery_issue_reason_required' using errcode = '22023';
  end if;

  select *
  into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'order_not_found' using errcode = 'P0002';
  end if;

  v_order_json := to_jsonb(v_order);
  v_owner_text := coalesce(
    nullif(trim(v_order_json ->> 'customer_id'), ''),
    nullif(trim(v_order_json ->> 'user_id'), '')
  );

  if v_owner_text is null then
    raise exception 'order_owner_missing' using errcode = '42501';
  end if;

  begin
    v_owner_id := v_owner_text::uuid;
  exception
    when others then
      raise exception 'order_owner_invalid' using errcode = '42501';
  end;

  if v_owner_id <> v_user_id then
    raise exception 'order_forbidden' using errcode = '42501';
  end if;

  v_status := lower(replace(coalesce(trim(v_order_json ->> 'status'), ''), '-', '_'));
  if v_status <> 'awaiting_customer_confirmation' then
    raise exception 'invalid_order_state:%', v_status using errcode = '22023';
  end if;

  if p_authoritative_state_version is not null
      and coalesce(v_order.authoritative_state_version, 0) <> p_authoritative_state_version then
    raise exception 'stale_order_state' using errcode = '40001';
  end if;

  if p_order_version is not null
      and coalesce(v_order.order_version, 0) <> p_order_version then
    raise exception 'stale_order_state' using errcode = '40001';
  end if;

  insert into public.customer_delivery_issues (
    order_id,
    customer_user_id,
    reason,
    order_status,
    authoritative_state_version,
    order_version,
    metadata
  )
  values (
    p_order_id,
    v_user_id,
    v_reason,
    v_status,
    coalesce(v_order.authoritative_state_version, 0),
    coalesce(v_order.order_version, 0),
    jsonb_build_object('source', 'restaurant_customer')
  )
  returning id into v_issue_id;

  return jsonb_build_object(
    'ok', true,
    'issue_id', v_issue_id,
    'order_id', p_order_id,
    'status', v_status
  );
end;
$$;

revoke all on function public.report_delivery_issue(uuid, text, bigint, bigint)
  from public;
grant execute on function public.report_delivery_issue(uuid, text, bigint, bigint)
  to authenticated;
