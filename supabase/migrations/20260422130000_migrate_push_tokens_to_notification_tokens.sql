create extension if not exists pgcrypto;

create table if not exists public.notification_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fcm_token text not null,
  platform text not null,
  device_info jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  last_error text,
  last_seen_at timestamptz not null default timezone('utc', now()),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint notification_tokens_user_id_fcm_token_unique unique (user_id, fcm_token)
);

alter table if exists public.notification_tokens
  add column if not exists user_id uuid references auth.users(id) on delete cascade,
  add column if not exists fcm_token text,
  add column if not exists platform text,
  add column if not exists device_info jsonb,
  add column if not exists is_active boolean,
  add column if not exists last_error text,
  add column if not exists last_seen_at timestamptz,
  add column if not exists created_at timestamptz,
  add column if not exists updated_at timestamptz;

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'notification_tokens'
      and column_name = 'token'
  ) then
    update public.notification_tokens
    set fcm_token = coalesce(
      nullif(trim(fcm_token), ''),
      nullif(trim(token), '')
    )
    where coalesce(nullif(trim(fcm_token), ''), nullif(trim(token), '')) is not null;
  end if;
end;
$$;

update public.notification_tokens
set
  device_info = coalesce(device_info, '{}'::jsonb),
  is_active = coalesce(is_active, true),
  last_seen_at = coalesce(last_seen_at, timezone('utc', now())),
  created_at = coalesce(created_at, timezone('utc', now())),
  updated_at = coalesce(updated_at, timezone('utc', now()));

alter table if exists public.notification_tokens
  alter column device_info set default '{}'::jsonb,
  alter column is_active set default true,
  alter column last_seen_at set default timezone('utc', now()),
  alter column created_at set default timezone('utc', now()),
  alter column updated_at set default timezone('utc', now());

drop index if exists public.notification_tokens_user_id_fcm_token_unique_idx;
create unique index if not exists notification_tokens_user_id_fcm_token_unique_idx
  on public.notification_tokens (user_id, fcm_token)
  where fcm_token is not null;

create index if not exists notification_tokens_user_active_idx
  on public.notification_tokens (user_id, is_active, updated_at desc);

create index if not exists notification_tokens_platform_active_idx
  on public.notification_tokens (platform, is_active, updated_at desc);

drop trigger if exists notification_tokens_set_updated_at on public.notification_tokens;
create trigger notification_tokens_set_updated_at
before update on public.notification_tokens
for each row
execute function public.set_updated_at();

insert into public.notification_tokens (
  id,
  user_id,
  fcm_token,
  platform,
  device_info,
  is_active,
  last_error,
  last_seen_at,
  created_at,
  updated_at
)
select
  upt.id,
  upt.user_id,
  upt.token,
  upt.platform,
  jsonb_build_object(
    'installation_id',
    'legacy-' || upt.id::text,
    'legacy_device_label',
    coalesce(upt.device_label, '')
  ),
  upt.is_active,
  upt.last_error,
  upt.last_seen_at,
  upt.created_at,
  upt.updated_at
from public.user_push_tokens upt
where not exists (
  select 1
  from public.notification_tokens nt
  where nt.fcm_token = upt.token
);

update public.notification_tokens nt
set
  user_id = upt.user_id,
  platform = upt.platform,
  device_info = coalesce(nt.device_info, '{}'::jsonb) || jsonb_build_object(
    'legacy_device_label',
    coalesce(upt.device_label, '')
  ),
  is_active = upt.is_active,
  last_error = upt.last_error,
  last_seen_at = upt.last_seen_at,
  created_at = least(nt.created_at, upt.created_at),
  updated_at = greatest(nt.updated_at, upt.updated_at)
from public.user_push_tokens upt
where nt.fcm_token = upt.token;

update public.notification_delivery_logs logs
set token_id = nt.id
from public.user_push_tokens upt
join public.notification_tokens nt
  on nt.fcm_token = upt.token
where logs.token_id = upt.id
  and logs.token_id is distinct from nt.id;

do $$
declare
  fk record;
begin
  for fk in
    select conname
    from pg_constraint
    where conrelid = 'public.notification_delivery_logs'::regclass
      and contype = 'f'
      and confrelid = 'public.user_push_tokens'::regclass
  loop
    execute format(
      'alter table public.notification_delivery_logs drop constraint %I',
      fk.conname
    );
  end loop;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.notification_delivery_logs'::regclass
      and conname = 'notification_delivery_logs_token_id_fkey'
  ) then
    alter table public.notification_delivery_logs
      add constraint notification_delivery_logs_token_id_fkey
      foreign key (token_id)
      references public.notification_tokens(id)
      on delete set null;
  end if;
end;
$$;

alter table public.notification_tokens enable row level security;

drop policy if exists "notification_tokens_select_own" on public.notification_tokens;
create policy "notification_tokens_select_own"
on public.notification_tokens
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "notification_tokens_insert_own" on public.notification_tokens;
create policy "notification_tokens_insert_own"
on public.notification_tokens
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "notification_tokens_update_own" on public.notification_tokens;
create policy "notification_tokens_update_own"
on public.notification_tokens
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "notification_tokens_delete_own" on public.notification_tokens;
create policy "notification_tokens_delete_own"
on public.notification_tokens
for delete
to authenticated
using (auth.uid() = user_id);

create or replace function public.upsert_notification_token(
  p_fcm_token text,
  p_platform text,
  p_device_info jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_fcm_token text := nullif(trim(p_fcm_token), '');
  v_platform text := nullif(trim(p_platform), '');
  v_device_info jsonb := coalesce(p_device_info, '{}'::jsonb);
  v_installation_id text := nullif(v_device_info ->> 'installation_id', '');
  v_token_id uuid;
begin
  if v_user_id is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if v_fcm_token is null then
    raise exception 'token_required' using errcode = '22023';
  end if;

  if v_platform is null then
    raise exception 'platform_required' using errcode = '22023';
  end if;

  insert into public.notification_tokens (
    user_id,
    fcm_token,
    platform,
    device_info,
    is_active,
    last_error,
    last_seen_at
  )
  values (
    v_user_id,
    v_fcm_token,
    v_platform,
    v_device_info,
    true,
    null,
    timezone('utc', now())
  )
  on conflict (user_id, fcm_token)
  do update
    set platform = excluded.platform,
        device_info = excluded.device_info,
        is_active = true,
        last_error = null,
        last_seen_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
  returning id into v_token_id;

  if v_installation_id is not null then
    update public.notification_tokens
    set
      is_active = false,
      last_error = 'superseded_by_new_token',
      last_seen_at = timezone('utc', now()),
      updated_at = timezone('utc', now())
    where user_id = v_user_id
      and platform = v_platform
      and fcm_token <> v_fcm_token
      and coalesce(device_info ->> 'installation_id', '') = v_installation_id
      and is_active = true;
  end if;

  return v_token_id;
end;
$$;

revoke all on function public.upsert_notification_token(text, text, jsonb) from public;
grant execute on function public.upsert_notification_token(text, text, jsonb) to authenticated;

create or replace function public.deactivate_notification_token(
  p_fcm_token text,
  p_reason text default 'manual_deactivate'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_fcm_token text := nullif(trim(p_fcm_token), '');
  v_reason text := coalesce(nullif(trim(p_reason), ''), 'manual_deactivate');
begin
  if v_user_id is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if v_fcm_token is null then
    return;
  end if;

  update public.notification_tokens
  set
    is_active = false,
    last_error = v_reason,
    last_seen_at = timezone('utc', now()),
    updated_at = timezone('utc', now())
  where user_id = v_user_id
    and fcm_token = v_fcm_token;
end;
$$;

revoke all on function public.deactivate_notification_token(text, text) from public;
grant execute on function public.deactivate_notification_token(text, text) to authenticated;
