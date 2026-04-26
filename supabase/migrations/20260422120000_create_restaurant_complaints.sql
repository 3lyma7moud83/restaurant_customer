create extension if not exists pgcrypto;

create or replace function public.is_admin_user()
returns boolean
language sql
stable
as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false);
$$;

create table if not exists public.restaurant_complaints (
  id uuid primary key default gen_random_uuid(),
  restaurant_id text not null,
  customer_id uuid not null references auth.users(id) on delete cascade,
  order_id uuid references public.orders(id) on delete set null,
  title text not null,
  message text not null,
  status text not null default 'pending'
    check (status in ('pending', 'in_review', 'resolved', 'rejected')),
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists restaurant_complaints_restaurant_created_idx
  on public.restaurant_complaints (restaurant_id, created_at desc);

create index if not exists restaurant_complaints_customer_created_idx
  on public.restaurant_complaints (customer_id, created_at desc);

create index if not exists restaurant_complaints_status_created_idx
  on public.restaurant_complaints (status, created_at desc);

alter table public.restaurant_complaints enable row level security;

drop policy if exists "restaurant_complaints_insert_own"
  on public.restaurant_complaints;
create policy "restaurant_complaints_insert_own"
on public.restaurant_complaints
for insert
to authenticated
with check (auth.uid() = user_id and auth.uid() = customer_id);

drop policy if exists "restaurant_complaints_select_own"
  on public.restaurant_complaints;
create policy "restaurant_complaints_select_own"
on public.restaurant_complaints
for select
to authenticated
using (auth.uid() = user_id or auth.uid() = customer_id);

drop policy if exists "restaurant_complaints_select_admin"
  on public.restaurant_complaints;
create policy "restaurant_complaints_select_admin"
on public.restaurant_complaints
for select
to authenticated
using (public.is_admin_user());

drop policy if exists "restaurant_complaints_update_admin"
  on public.restaurant_complaints;
create policy "restaurant_complaints_update_admin"
on public.restaurant_complaints
for update
to authenticated
using (public.is_admin_user())
with check (public.is_admin_user());
