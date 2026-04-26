create extension if not exists pgcrypto;

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
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

alter table public.customer_addresses
  add column if not exists is_primary boolean,
  add column if not exists lat double precision,
  add column if not exists lng double precision,
  add column if not exists additional_notes text;

update public.customer_addresses
set additional_notes = coalesce(additional_notes, '')
where additional_notes is null;

alter table public.customer_addresses
  alter column additional_notes set default '',
  alter column additional_notes set not null;

update public.customer_addresses
set is_primary = true
where is_primary is distinct from true;

alter table public.customer_addresses
  alter column is_primary set default true,
  alter column is_primary set not null;

with ranked as (
  select
    id,
    row_number() over (
      partition by user_id
      order by updated_at desc, created_at desc, id desc
    ) as rn
  from public.customer_addresses
)
delete from public.customer_addresses target
using ranked
where target.id = ranked.id
  and ranked.rn > 1;

create unique index if not exists customer_addresses_user_id_unique_idx
  on public.customer_addresses (user_id);

create index if not exists customer_addresses_user_updated_idx
  on public.customer_addresses (user_id, updated_at desc);

create or replace function public.customer_addresses_force_primary_value()
returns trigger
language plpgsql
as $$
begin
  new.is_primary := true;
  return new;
end;
$$;

drop trigger if exists customer_addresses_force_primary_value_trigger
  on public.customer_addresses;
create trigger customer_addresses_force_primary_value_trigger
before insert or update
on public.customer_addresses
for each row
execute function public.customer_addresses_force_primary_value();

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
  updated_at timestamptz not null default timezone('utc', now())
);

alter table public.notification_tokens
  add column if not exists device_info jsonb,
  add column if not exists is_active boolean,
  add column if not exists last_error text,
  add column if not exists last_seen_at timestamptz,
  add column if not exists created_at timestamptz,
  add column if not exists updated_at timestamptz;

update public.notification_tokens
set
  device_info = coalesce(device_info, '{}'::jsonb),
  is_active = coalesce(is_active, true),
  last_seen_at = coalesce(last_seen_at, timezone('utc', now())),
  created_at = coalesce(created_at, timezone('utc', now())),
  updated_at = coalesce(updated_at, timezone('utc', now()));

alter table public.notification_tokens
  alter column device_info set default '{}'::jsonb,
  alter column device_info set not null,
  alter column is_active set default true,
  alter column is_active set not null,
  alter column last_seen_at set default timezone('utc', now()),
  alter column last_seen_at set not null,
  alter column created_at set default timezone('utc', now()),
  alter column created_at set not null,
  alter column updated_at set default timezone('utc', now()),
  alter column updated_at set not null;

with ranked as (
  select
    id,
    row_number() over (
      partition by user_id, fcm_token
      order by updated_at desc, created_at desc, id desc
    ) as rn
  from public.notification_tokens
)
delete from public.notification_tokens target
using ranked
where target.id = ranked.id
  and ranked.rn > 1;

create unique index if not exists notification_tokens_user_id_fcm_token_unique_idx
  on public.notification_tokens (user_id, fcm_token);

create index if not exists notification_tokens_user_active_idx
  on public.notification_tokens (user_id, is_active, updated_at desc);

create index if not exists notification_tokens_platform_active_idx
  on public.notification_tokens (platform, is_active, updated_at desc);

drop trigger if exists notification_tokens_set_updated_at on public.notification_tokens;
create trigger notification_tokens_set_updated_at
before update on public.notification_tokens
for each row
execute function public.set_updated_at();

with ranked_installations as (
  select
    id,
    row_number() over (
      partition by user_id, platform, coalesce(device_info ->> 'installation_id', '')
      order by updated_at desc, created_at desc, id desc
    ) as rn
  from public.notification_tokens
  where is_active = true
    and coalesce(device_info ->> 'installation_id', '') <> ''
)
update public.notification_tokens token
set
  is_active = false,
  last_error = 'superseded_by_latest_installation_token',
  last_seen_at = timezone('utc', now()),
  updated_at = timezone('utc', now())
from ranked_installations ranked
where token.id = ranked.id
  and ranked.rn > 1;

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
        device_info = coalesce(public.notification_tokens.device_info, '{}'::jsonb) || excluded.device_info,
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

create table if not exists public.notification_dispatch_config (
  id boolean primary key default true check (id = true),
  function_url text not null,
  function_auth_token text,
  is_enabled boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

drop trigger if exists notification_dispatch_config_set_updated_at on public.notification_dispatch_config;
create trigger notification_dispatch_config_set_updated_at
before update on public.notification_dispatch_config
for each row
execute function public.set_updated_at();

revoke all on table public.notification_dispatch_config from anon, authenticated;
grant select, insert, update on table public.notification_dispatch_config to service_role;

create or replace function public.configure_notification_dispatch(
  p_function_url text,
  p_function_auth_token text default null,
  p_is_enabled boolean default true
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text := nullif(trim(p_function_url), '');
  v_token text := nullif(trim(coalesce(p_function_auth_token, '')), '');
begin
  if v_url is null then
    raise exception 'function_url_required' using errcode = '22023';
  end if;

  insert into public.notification_dispatch_config (
    id,
    function_url,
    function_auth_token,
    is_enabled
  )
  values (
    true,
    v_url,
    v_token,
    coalesce(p_is_enabled, true)
  )
  on conflict (id)
  do update
    set function_url = excluded.function_url,
        function_auth_token = excluded.function_auth_token,
        is_enabled = excluded.is_enabled,
        updated_at = timezone('utc', now());
end;
$$;

revoke all on function public.configure_notification_dispatch(text, text, boolean) from public;
grant execute on function public.configure_notification_dispatch(text, text, boolean) to service_role;

create or replace function public.enqueue_notification_processing()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_config public.notification_dispatch_config%rowtype;
  v_headers jsonb := jsonb_build_object('Content-Type', 'application/json');
  v_body jsonb;
begin
  if new.status <> 'pending' then
    return new;
  end if;

  select *
  into v_config
  from public.notification_dispatch_config
  where id = true
    and is_enabled = true
  limit 1;

  if v_config.id is distinct from true then
    return new;
  end if;

  if coalesce(v_config.function_auth_token, '') <> '' then
    v_headers := v_headers || jsonb_build_object(
      'Authorization',
      'Bearer ' || v_config.function_auth_token
    );
  end if;

  v_body := jsonb_build_object(
    'trigger', tg_op,
    'notification_id', new.id
  );

  begin
    execute
      'select net.http_post(url := $1, headers := $2, body := $3)'
      using v_config.function_url, v_headers, v_body;
  exception
    when undefined_function then
      null;
    when others then
      null;
  end;

  return new;
end;
$$;

revoke all on function public.enqueue_notification_processing() from public;
grant execute on function public.enqueue_notification_processing() to service_role;

drop trigger if exists notifications_enqueue_processing_on_insert on public.notifications;
create trigger notifications_enqueue_processing_on_insert
after insert
on public.notifications
for each row
when (new.status = 'pending')
execute function public.enqueue_notification_processing();

drop trigger if exists notifications_enqueue_processing_on_update on public.notifications;
create trigger notifications_enqueue_processing_on_update
after update of status
on public.notifications
for each row
when (new.status = 'pending' and old.status is distinct from new.status)
execute function public.enqueue_notification_processing();
