create extension if not exists pgcrypto;

create table if not exists public.system_errors (
  id uuid primary key default gen_random_uuid(),
  app_name text not null,
  module text not null,
  error_message text not null,
  stack_trace text,
  user_id uuid,
  created_at timestamptz not null default now()
);

alter table public.system_errors enable row level security;

create policy "allow system error inserts"
on public.system_errors
for insert
to anon, authenticated
with check (app_name = 'customer_app');
