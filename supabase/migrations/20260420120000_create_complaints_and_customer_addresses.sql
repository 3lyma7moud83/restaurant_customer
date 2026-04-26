create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

create or replace function public.is_admin_user()
returns boolean
language sql
stable
as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false);
$$;

create table if not exists public.complaints (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  customer_name text not null,
  customer_phone text not null,
  restaurant_id text,
  complaint_title text not null,
  complaint_message text not null,
  status text not null default 'pending'
    check (status in ('pending', 'in_review', 'resolved', 'rejected')),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create index if not exists complaints_user_created_idx
  on public.complaints (user_id, created_at desc);

create index if not exists complaints_status_created_idx
  on public.complaints (status, created_at desc);

create index if not exists complaints_restaurant_created_idx
  on public.complaints (restaurant_id, created_at desc);

drop trigger if exists complaints_set_updated_at on public.complaints;
create trigger complaints_set_updated_at
before update on public.complaints
for each row
execute function public.set_updated_at();

alter table public.complaints enable row level security;

drop policy if exists "complaints_insert_own" on public.complaints;
create policy "complaints_insert_own"
on public.complaints
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "complaints_select_own" on public.complaints;
create policy "complaints_select_own"
on public.complaints
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "complaints_select_admin" on public.complaints;
create policy "complaints_select_admin"
on public.complaints
for select
to authenticated
using (public.is_admin_user());

drop policy if exists "complaints_update_admin" on public.complaints;
create policy "complaints_update_admin"
on public.complaints
for update
to authenticated
using (public.is_admin_user())
with check (public.is_admin_user());

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  primary_address text not null,
  house_apartment_no text not null,
  area text not null,
  additional_notes text not null default '',
  is_primary boolean not null default true,
  lat double precision,
  lng double precision,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create index if not exists customer_addresses_user_updated_idx
  on public.customer_addresses (user_id, updated_at desc);

drop trigger if exists customer_addresses_set_updated_at on public.customer_addresses;
create trigger customer_addresses_set_updated_at
before update on public.customer_addresses
for each row
execute function public.set_updated_at();

alter table public.customer_addresses enable row level security;

drop policy if exists "customer_addresses_select_own" on public.customer_addresses;
create policy "customer_addresses_select_own"
on public.customer_addresses
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "customer_addresses_insert_own" on public.customer_addresses;
create policy "customer_addresses_insert_own"
on public.customer_addresses
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "customer_addresses_update_own" on public.customer_addresses;
create policy "customer_addresses_update_own"
on public.customer_addresses
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "customer_addresses_delete_own" on public.customer_addresses;
create policy "customer_addresses_delete_own"
on public.customer_addresses
for delete
to authenticated
using (auth.uid() = user_id);
