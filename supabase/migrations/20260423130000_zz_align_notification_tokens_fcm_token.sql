create extension if not exists pgcrypto;

alter table if exists public.notification_tokens
  add column if not exists fcm_token text;

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

delete from public.notification_tokens
where nullif(trim(fcm_token), '') is null;

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

do $$
begin
  if exists (
    select 1
    from pg_constraint
    where conrelid = 'public.notification_tokens'::regclass
      and conname = 'notification_tokens_token_unique'
  ) then
    alter table public.notification_tokens
      drop constraint notification_tokens_token_unique;
  end if;
end;
$$;

drop index if exists public.notification_tokens_token_unique_idx;
drop index if exists public.notification_tokens_user_fcm_token_unique_idx;

create unique index if not exists notification_tokens_user_id_fcm_token_unique_idx
  on public.notification_tokens (user_id, fcm_token);

alter table if exists public.notification_tokens
  alter column fcm_token set not null;

alter table if exists public.notification_tokens
  drop column if exists token;

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

  update public.notification_tokens
  set
    is_active = false,
    last_error = 'reassigned_to_another_user',
    last_seen_at = timezone('utc', now()),
    updated_at = timezone('utc', now())
  where user_id <> v_user_id
    and fcm_token = v_fcm_token
    and is_active = true;

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
