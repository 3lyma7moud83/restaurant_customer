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

create table if not exists public.customer_device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fcm_token text not null,
  platform text not null,
  is_active boolean not null default true,
  is_samsung boolean not null default false,
  android_major smallint,
  android_version text,
  supports_http_v1 boolean not null default true,
  device_info jsonb not null default '{}'::jsonb,
  last_error text,
  last_seen_at timestamptz not null default timezone('utc', now()),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint customer_device_tokens_platform_chk check (
    platform in ('android', 'web', 'ios', 'windows', 'macos', 'linux', 'fuchsia', 'unknown')
  ),
  constraint customer_device_tokens_token_not_blank_chk check (length(trim(fcm_token)) > 0)
);

create unique index if not exists customer_device_tokens_user_token_uidx
  on public.customer_device_tokens (user_id, fcm_token);

create index if not exists customer_device_tokens_user_active_idx
  on public.customer_device_tokens (user_id, is_active, updated_at desc);

create index if not exists customer_device_tokens_platform_active_idx
  on public.customer_device_tokens (platform, is_active, updated_at desc);

create index if not exists customer_device_tokens_fcm_token_idx
  on public.customer_device_tokens (fcm_token);

create index if not exists customer_device_tokens_samsung_android_idx
  on public.customer_device_tokens (is_samsung, android_major, is_active, updated_at desc);

create index if not exists customer_device_tokens_http_v1_idx
  on public.customer_device_tokens (supports_http_v1, is_active, updated_at desc);

drop trigger if exists customer_device_tokens_set_updated_at on public.customer_device_tokens;
create trigger customer_device_tokens_set_updated_at
before update on public.customer_device_tokens
for each row
execute function public.set_updated_at();

alter table public.customer_device_tokens enable row level security;

drop policy if exists "customer_device_tokens_select_own" on public.customer_device_tokens;
create policy "customer_device_tokens_select_own"
on public.customer_device_tokens
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "customer_device_tokens_insert_own" on public.customer_device_tokens;
create policy "customer_device_tokens_insert_own"
on public.customer_device_tokens
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "customer_device_tokens_update_own" on public.customer_device_tokens;
create policy "customer_device_tokens_update_own"
on public.customer_device_tokens
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "customer_device_tokens_delete_own" on public.customer_device_tokens;
create policy "customer_device_tokens_delete_own"
on public.customer_device_tokens
for delete
to authenticated
using (auth.uid() = user_id);

create or replace function public.upsert_customer_device_token(
  p_fcm_token text,
  p_platform text,
  p_supports_http_v1 boolean default true,
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
  v_platform text := lower(coalesce(nullif(trim(p_platform), ''), 'unknown'));
  v_device_info jsonb := coalesce(p_device_info, '{}'::jsonb);
  v_supports_http_v1 boolean := coalesce(p_supports_http_v1, true);
  v_detection_blob text;
  v_is_samsung boolean := false;
  v_android_version text;
  v_android_major smallint;
  v_installation_id text := nullif(trim(v_device_info ->> 'installation_id'), '');
  v_token_id uuid;
begin
  if v_user_id is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if v_fcm_token is null then
    raise exception 'token_required' using errcode = '22023';
  end if;

  if v_platform not in ('android', 'web', 'ios', 'windows', 'macos', 'linux', 'fuchsia', 'unknown') then
    v_platform := 'unknown';
  end if;

  v_detection_blob := lower(
    concat_ws(
      ' ',
      coalesce(v_device_info ->> 'manufacturer', ''),
      coalesce(v_device_info ->> 'brand', ''),
      coalesce(v_device_info ->> 'model', ''),
      coalesce(v_device_info ->> 'user_agent', ''),
      coalesce(v_device_info ->> 'device', '')
    )
  );
  v_is_samsung :=
    position('samsung' in v_detection_blob) > 0
    or lower(coalesce(v_device_info ->> 'is_samsung', '')) in ('1', 'true', 'yes');

  v_android_version := nullif(
    trim(
      coalesce(
        v_device_info ->> 'android_version',
        v_device_info ->> 'os_version',
        v_device_info ->> 'platform_version',
        ''
      )
    ),
    ''
  );
  if v_android_version is null then
    v_android_version := nullif(substring(v_detection_blob from 'android[ /]?([0-9]{1,2})'), '');
  end if;

  if v_android_version is not null then
    begin
      v_android_major := nullif(substring(v_android_version from '^([0-9]{1,2})'), '')::smallint;
    exception
      when others then
        v_android_major := null;
    end;
  end if;

  insert into public.customer_device_tokens (
    user_id,
    fcm_token,
    platform,
    is_active,
    is_samsung,
    android_major,
    android_version,
    supports_http_v1,
    device_info,
    last_error,
    last_seen_at
  )
  values (
    v_user_id,
    v_fcm_token,
    v_platform,
    true,
    v_is_samsung,
    v_android_major,
    v_android_version,
    v_supports_http_v1,
    v_device_info,
    null,
    timezone('utc', now())
  )
  on conflict (user_id, fcm_token)
  do update
    set platform = excluded.platform,
        is_active = true,
        is_samsung = excluded.is_samsung,
        android_major = excluded.android_major,
        android_version = excluded.android_version,
        supports_http_v1 = excluded.supports_http_v1,
        device_info = coalesce(public.customer_device_tokens.device_info, '{}'::jsonb) || excluded.device_info,
        last_error = null,
        last_seen_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
  returning id into v_token_id;

  update public.customer_device_tokens
  set
    is_active = false,
    last_error = 'reassigned_to_another_user',
    last_seen_at = timezone('utc', now()),
    updated_at = timezone('utc', now())
  where user_id <> v_user_id
    and fcm_token = v_fcm_token
    and is_active = true;

  if v_installation_id is not null then
    update public.customer_device_tokens
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

revoke all on function public.upsert_customer_device_token(text, text, boolean, jsonb) from public;
grant execute on function public.upsert_customer_device_token(text, text, boolean, jsonb) to authenticated;

create or replace function public.deactivate_customer_device_token(
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

  update public.customer_device_tokens
  set
    is_active = false,
    last_error = v_reason,
    last_seen_at = timezone('utc', now()),
    updated_at = timezone('utc', now())
  where user_id = v_user_id
    and fcm_token = v_fcm_token;
end;
$$;

revoke all on function public.deactivate_customer_device_token(text, text) from public;
grant execute on function public.deactivate_customer_device_token(text, text) to authenticated;

create or replace function public.sync_legacy_notification_token_to_customer_device_tokens()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_detection_blob text;
  v_is_samsung boolean := false;
  v_android_version text;
  v_android_major smallint;
begin
  if new.user_id is null then
    return new;
  end if;

  if nullif(trim(new.fcm_token), '') is null then
    return new;
  end if;

  v_detection_blob := lower(
    concat_ws(
      ' ',
      coalesce(new.device_info ->> 'manufacturer', ''),
      coalesce(new.device_info ->> 'brand', ''),
      coalesce(new.device_info ->> 'model', ''),
      coalesce(new.device_info ->> 'user_agent', ''),
      coalesce(new.device_info ->> 'device', '')
    )
  );
  v_is_samsung :=
    position('samsung' in v_detection_blob) > 0
    or lower(coalesce(new.device_info ->> 'is_samsung', '')) in ('1', 'true', 'yes');

  v_android_version := nullif(
    trim(
      coalesce(
        new.device_info ->> 'android_version',
        new.device_info ->> 'os_version',
        new.device_info ->> 'platform_version',
        ''
      )
    ),
    ''
  );
  if v_android_version is null then
    v_android_version := nullif(substring(v_detection_blob from 'android[ /]?([0-9]{1,2})'), '');
  end if;

  if v_android_version is not null then
    begin
      v_android_major := nullif(substring(v_android_version from '^([0-9]{1,2})'), '')::smallint;
    exception
      when others then
        v_android_major := null;
    end;
  end if;

  insert into public.customer_device_tokens (
    user_id,
    fcm_token,
    platform,
    is_active,
    is_samsung,
    android_major,
    android_version,
    supports_http_v1,
    device_info,
    last_error,
    last_seen_at
  )
  values (
    new.user_id,
    new.fcm_token,
    lower(coalesce(nullif(trim(new.platform), ''), 'unknown')),
    coalesce(new.is_active, true),
    v_is_samsung,
    v_android_major,
    v_android_version,
    true,
    coalesce(new.device_info, '{}'::jsonb),
    new.last_error,
    coalesce(new.last_seen_at, timezone('utc', now()))
  )
  on conflict (user_id, fcm_token)
  do update
    set platform = excluded.platform,
        is_active = excluded.is_active,
        is_samsung = excluded.is_samsung,
        android_major = excluded.android_major,
        android_version = excluded.android_version,
        supports_http_v1 = excluded.supports_http_v1,
        device_info = coalesce(public.customer_device_tokens.device_info, '{}'::jsonb) || excluded.device_info,
        last_error = excluded.last_error,
        last_seen_at = excluded.last_seen_at,
        updated_at = timezone('utc', now());

  return new;
end;
$$;

revoke all on function public.sync_legacy_notification_token_to_customer_device_tokens() from public;
grant execute on function public.sync_legacy_notification_token_to_customer_device_tokens() to service_role;

drop trigger if exists notification_tokens_sync_customer_device_tokens_tr on public.notification_tokens;
create trigger notification_tokens_sync_customer_device_tokens_tr
after insert or update of fcm_token, platform, is_active, device_info, last_error, last_seen_at
on public.notification_tokens
for each row
execute function public.sync_legacy_notification_token_to_customer_device_tokens();

insert into public.customer_device_tokens (
  user_id,
  fcm_token,
  platform,
  is_active,
  is_samsung,
  android_major,
  android_version,
  supports_http_v1,
  device_info,
  last_error,
  last_seen_at
)
select
  nt.user_id,
  nt.fcm_token,
  lower(coalesce(nullif(trim(nt.platform), ''), 'unknown')),
  coalesce(nt.is_active, true),
  (
    position(
      'samsung' in lower(
        concat_ws(
          ' ',
          coalesce(nt.device_info ->> 'manufacturer', ''),
          coalesce(nt.device_info ->> 'brand', ''),
          coalesce(nt.device_info ->> 'model', ''),
          coalesce(nt.device_info ->> 'user_agent', ''),
          coalesce(nt.device_info ->> 'device', '')
        )
      )
    ) > 0
    or lower(coalesce(nt.device_info ->> 'is_samsung', '')) in ('1', 'true', 'yes')
  ),
  nullif(
    substring(
      coalesce(
        nt.device_info ->> 'android_major',
        nt.device_info ->> 'android_version',
        nt.device_info ->> 'os_version',
        nt.device_info ->> 'platform_version',
        ''
      )
      from '^([0-9]{1,2})'
    ),
    ''
  )::smallint,
  nullif(
    trim(
      coalesce(
        nt.device_info ->> 'android_version',
        nt.device_info ->> 'os_version',
        nt.device_info ->> 'platform_version',
        ''
      )
    ),
    ''
  ),
  true,
  coalesce(nt.device_info, '{}'::jsonb),
  nt.last_error,
  coalesce(nt.last_seen_at, timezone('utc', now()))
from public.notification_tokens nt
where nt.user_id is not null
  and nullif(trim(nt.fcm_token), '') is not null
on conflict (user_id, fcm_token)
do update
  set platform = excluded.platform,
      is_active = excluded.is_active,
      is_samsung = excluded.is_samsung,
      android_major = excluded.android_major,
      android_version = excluded.android_version,
      supports_http_v1 = excluded.supports_http_v1,
      device_info = coalesce(public.customer_device_tokens.device_info, '{}'::jsonb) || excluded.device_info,
      last_error = excluded.last_error,
      last_seen_at = excluded.last_seen_at,
      updated_at = timezone('utc', now());

create table if not exists public.customer_notifications (
  id uuid primary key default gen_random_uuid(),
  customer_user_id uuid not null references auth.users(id) on delete cascade,
  order_id uuid,
  status_key text,
  title text not null,
  body text not null,
  payload jsonb not null default '{}'::jsonb,
  source text not null default 'manual',
  channel text not null default 'push_customer',
  delivery_status text not null default 'queued'
    check (delivery_status in ('queued', 'processing', 'sent', 'failed')),
  retries_count integer not null default 0 check (retries_count >= 0),
  queue_id bigint,
  queued_at timestamptz,
  pushed_at timestamptz,
  failed_at timestamptz,
  last_error text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create index if not exists customer_notifications_user_created_idx
  on public.customer_notifications (customer_user_id, created_at desc);

create index if not exists customer_notifications_delivery_status_idx
  on public.customer_notifications (delivery_status, created_at);

create index if not exists customer_notifications_order_idx
  on public.customer_notifications (order_id, created_at desc)
  where order_id is not null;

create index if not exists customer_notifications_queue_idx
  on public.customer_notifications (queue_id)
  where queue_id is not null;

drop trigger if exists customer_notifications_set_updated_at on public.customer_notifications;
create trigger customer_notifications_set_updated_at
before update on public.customer_notifications
for each row
execute function public.set_updated_at();

alter table public.customer_notifications enable row level security;

drop policy if exists "customer_notifications_select_own" on public.customer_notifications;
create policy "customer_notifications_select_own"
on public.customer_notifications
for select
to authenticated
using (auth.uid() = customer_user_id);

drop policy if exists "customer_notifications_insert_own" on public.customer_notifications;
create policy "customer_notifications_insert_own"
on public.customer_notifications
for insert
to authenticated
with check (auth.uid() = customer_user_id);

create table if not exists public.queue_customer_fcm (
  id bigint generated by default as identity primary key,
  notification_id uuid not null references public.customer_notifications(id) on delete cascade,
  customer_user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'sent', 'retry', 'failed')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  max_attempts integer not null default 6 check (max_attempts > 0),
  next_retry_at timestamptz not null default timezone('utc', now()),
  processing_started_at timestamptz,
  sent_at timestamptz,
  failed_at timestamptz,
  last_error text,
  worker_id text,
  request_payload jsonb not null default '{}'::jsonb,
  response_payload jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

do $queue_fk$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.customer_notifications'::regclass
      and conname = 'customer_notifications_queue_id_fkey'
  ) then
    alter table public.customer_notifications
      add constraint customer_notifications_queue_id_fkey
      foreign key (queue_id)
      references public.queue_customer_fcm(id)
      on delete set null;
  end if;
end;
$queue_fk$;

create index if not exists queue_customer_fcm_dispatch_idx
  on public.queue_customer_fcm (status, next_retry_at, created_at);

create index if not exists queue_customer_fcm_notification_idx
  on public.queue_customer_fcm (notification_id);

create index if not exists queue_customer_fcm_customer_idx
  on public.queue_customer_fcm (customer_user_id, created_at desc);

create index if not exists queue_customer_fcm_attempt_idx
  on public.queue_customer_fcm (status, attempt_count, next_retry_at);

drop trigger if exists queue_customer_fcm_set_updated_at on public.queue_customer_fcm;
create trigger queue_customer_fcm_set_updated_at
before update on public.queue_customer_fcm
for each row
execute function public.set_updated_at();

alter table public.queue_customer_fcm enable row level security;

create or replace function public.claim_customer_fcm_queue(
  p_process_single_queue_id bigint default null,
  p_batch_limit integer default 100,
  p_worker_id text default null
)
returns setof public.queue_customer_fcm
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := timezone('utc', now());
  v_worker_id text := nullif(trim(coalesce(p_worker_id, '')), '');
  v_limit integer := greatest(1, least(coalesce(p_batch_limit, 100), 500));
begin
  return query
  with picked as (
    select q.id
    from public.queue_customer_fcm q
    where
      (
        p_process_single_queue_id is null
        and (
          (q.status in ('pending', 'retry') and q.next_retry_at <= v_now)
          or
          (
            q.status = 'processing'
            and coalesce(q.processing_started_at, q.updated_at, q.created_at) <= v_now - interval '30 seconds'
          )
        )
      )
      or
      (
        p_process_single_queue_id is not null
        and q.id = p_process_single_queue_id
        and (
          (q.status in ('pending', 'retry') and q.next_retry_at <= v_now)
          or
          (
            q.status = 'processing'
            and coalesce(q.processing_started_at, q.updated_at, q.created_at) <= v_now - interval '30 seconds'
          )
        )
      )
    order by q.created_at
    limit case when p_process_single_queue_id is null then v_limit else 1 end
    for update skip locked
  ),
  updated as (
    update public.queue_customer_fcm q
    set
      status = 'processing',
      processing_started_at = v_now,
      worker_id = coalesce(v_worker_id, q.worker_id),
      updated_at = v_now
    from picked
    where q.id = picked.id
    returning q.*
  )
  select * from updated;
end;
$$;

revoke all on function public.claim_customer_fcm_queue(bigint, integer, text) from public;
grant execute on function public.claim_customer_fcm_queue(bigint, integer, text) to service_role;

create table if not exists public.customer_notification_delivery_logs (
  id bigint generated by default as identity primary key,
  queue_id bigint not null references public.queue_customer_fcm(id) on delete cascade,
  notification_id uuid not null references public.customer_notifications(id) on delete cascade,
  token_id uuid references public.customer_device_tokens(id) on delete set null,
  request_payload jsonb not null,
  response_payload jsonb,
  error_message text,
  fcm_latency_ms integer,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists customer_notification_delivery_logs_queue_idx
  on public.customer_notification_delivery_logs (queue_id, created_at desc);

create index if not exists customer_notification_delivery_logs_notification_idx
  on public.customer_notification_delivery_logs (notification_id, created_at desc);

create table if not exists public.customer_fcm_dispatch_config (
  id boolean primary key default true check (id = true),
  function_url text not null,
  function_auth_token text,
  is_enabled boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

drop trigger if exists customer_fcm_dispatch_config_set_updated_at on public.customer_fcm_dispatch_config;
create trigger customer_fcm_dispatch_config_set_updated_at
before update on public.customer_fcm_dispatch_config
for each row
execute function public.set_updated_at();

revoke all on table public.customer_fcm_dispatch_config from anon, authenticated;
grant select, insert, update on table public.customer_fcm_dispatch_config to service_role;

do $seed_dispatch$
declare
  v_function_url text;
  v_function_auth_token text;
  v_is_enabled boolean;
begin
  if to_regclass('public.notification_dispatch_config') is null then
    return;
  end if;

  select
    nullif(trim(function_url), ''),
    nullif(trim(coalesce(function_auth_token, auth_token, '')), ''),
    coalesce(is_enabled, is_active, true)
  into
    v_function_url,
    v_function_auth_token,
    v_is_enabled
  from public.notification_dispatch_config
  order by updated_at desc nulls last, created_at desc nulls last
  limit 1;

  if v_function_url is null then
    return;
  end if;

  if v_function_url like '%/process-notifications' then
    v_function_url := replace(v_function_url, '/process-notifications', '/send-fcm');
  end if;

  insert into public.customer_fcm_dispatch_config (
    id,
    function_url,
    function_auth_token,
    is_enabled
  )
  values (
    true,
    v_function_url,
    v_function_auth_token,
    v_is_enabled
  )
  on conflict (id) do nothing;
end;
$seed_dispatch$;

create or replace function public.configure_customer_fcm_dispatch(
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
  v_enabled boolean := coalesce(p_is_enabled, true);
begin
  if v_url is null then
    raise exception 'function_url_required' using errcode = '22023';
  end if;

  insert into public.customer_fcm_dispatch_config (
    id,
    function_url,
    function_auth_token,
    is_enabled
  )
  values (
    true,
    v_url,
    v_token,
    v_enabled
  )
  on conflict (id)
  do update
    set function_url = excluded.function_url,
        function_auth_token = excluded.function_auth_token,
        is_enabled = excluded.is_enabled,
        updated_at = timezone('utc', now());
end;
$$;

revoke all on function public.configure_customer_fcm_dispatch(text, text, boolean) from public;
grant execute on function public.configure_customer_fcm_dispatch(text, text, boolean) to service_role;

create or replace function public.enqueue_customer_fcm()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_queue_id bigint;
  v_config public.customer_fcm_dispatch_config%rowtype;
  v_headers jsonb := jsonb_build_object('Content-Type', 'application/json');
  v_auth_token text;
  v_body jsonb;
begin
  insert into public.queue_customer_fcm (
    notification_id,
    customer_user_id,
    status,
    next_retry_at,
    request_payload
  )
  values (
    new.id,
    new.customer_user_id,
    'pending',
    timezone('utc', now()),
    coalesce(new.payload, '{}'::jsonb)
  )
  returning id into v_queue_id;

  update public.customer_notifications
  set
    queue_id = v_queue_id,
    queued_at = timezone('utc', now()),
    delivery_status = 'queued',
    retries_count = 0,
    last_error = null,
    updated_at = timezone('utc', now())
  where id = new.id;

  select *
  into v_config
  from public.customer_fcm_dispatch_config
  where coalesce(is_enabled, true) = true
  limit 1;

  if coalesce(nullif(trim(v_config.function_url), ''), '') = '' then
    return new;
  end if;

  v_auth_token := nullif(trim(coalesce(v_config.function_auth_token, '')), '');
  if v_auth_token is not null then
    v_headers := v_headers || jsonb_build_object(
      'Authorization',
      'Bearer ' || v_auth_token
    );
  end if;

  v_body := jsonb_build_object(
    'process_single_queue_id', v_queue_id,
    'target', 'customer'
  );

  begin
    perform net.http_post(
      url := v_config.function_url,
      headers := v_headers,
      body := v_body
    );
  exception
    when undefined_function then
      raise warning 'net.http_post is unavailable while enqueuing queue_customer_fcm %', v_queue_id;
    when others then
      raise warning 'enqueue_customer_fcm invoke failed for queue_id %: %', v_queue_id, sqlerrm;
  end;

  return new;
end;
$$;

revoke all on function public.enqueue_customer_fcm() from public;
grant execute on function public.enqueue_customer_fcm() to service_role;

drop trigger if exists customer_notifications_enqueue_tr on public.customer_notifications;
create trigger customer_notifications_enqueue_tr
after insert on public.customer_notifications
for each row
execute function public.enqueue_customer_fcm();

create or replace function public.customer_order_status_arabic_message(
  p_status text
)
returns table (
  normalized_status text,
  title text,
  body text
)
language plpgsql
immutable
as $$
declare
  v_status text := lower(replace(coalesce(trim(p_status), ''), '-', '_'));
begin
  if v_status in ('pending', 'pending_cashier') then
    return query select 'pending', 'تم استلام الطلب', 'جاري مراجعة طلبك';
    return;
  end if;

  if v_status in ('accepted', 'confirmed') then
    return query select 'accepted', 'تم قبول الطلب', 'المطعم بدأ تحضير طلبك';
    return;
  end if;

  if v_status in ('preparing', 'preparation', 'preparing_order') then
    return query select 'preparing', 'جاري التحضير', 'يتم الآن تجهيز طلبك';
    return;
  end if;

  if v_status in ('ready', 'prepared', 'ready_for_pickup') then
    return query select 'ready', 'الطلب جاهز', 'الطلب جاهز للتسليم';
    return;
  end if;

  if v_status in ('on_the_way', 'on_theway', 'onway', 'on_way', 'picked_up', 'arrived') then
    return query select 'on_the_way', 'الطلب في الطريق', 'الكابتن في الطريق إليك';
    return;
  end if;

  if v_status in ('delivered', 'delivered_final', 'delivered_confirmed', 'completed', 'done') then
    return query select 'delivered', 'تم التوصيل', 'تم تسليم الطلب بنجاح';
    return;
  end if;

  if v_status in ('cancelled', 'canceled') then
    return query select 'cancelled', 'تم إلغاء الطلب', 'تم إلغاء الطلب';
    return;
  end if;

  if v_status in ('rejected', 'declined') then
    return query select 'rejected', 'تم رفض الطلب', 'تعذر قبول الطلب';
    return;
  end if;
end;
$$;

create or replace function public.create_customer_notification_from_order_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_row jsonb := to_jsonb(new);
  v_old_row jsonb := to_jsonb(old);
  v_customer_text text;
  v_customer_user_id uuid;
  v_order_text text;
  v_order_id uuid;
  v_status text;
  v_prev_status text;
  v_mapped_status text;
  v_title text;
  v_body text;
begin
  v_status := lower(replace(coalesce(trim(v_new_row ->> 'status'), ''), '-', '_'));
  v_prev_status := lower(replace(coalesce(trim(v_old_row ->> 'status'), ''), '-', '_'));

  if v_status = '' or v_status = v_prev_status then
    return new;
  end if;

  select normalized_status, title, body
  into v_mapped_status, v_title, v_body
  from public.customer_order_status_arabic_message(v_status)
  limit 1;

  if coalesce(v_mapped_status, '') = '' then
    return new;
  end if;

  v_customer_text := coalesce(
    nullif(trim(v_new_row ->> 'customer_id'), ''),
    nullif(trim(v_new_row ->> 'user_id'), '')
  );
  if v_customer_text is null then
    return new;
  end if;

  begin
    v_customer_user_id := v_customer_text::uuid;
  exception
    when others then
      return new;
  end;

  v_order_text := nullif(trim(v_new_row ->> 'id'), '');
  if v_order_text is not null then
    begin
      v_order_id := v_order_text::uuid;
    exception
      when others then
        v_order_id := null;
    end;
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
  )
  values (
    v_customer_user_id,
    v_order_id,
    v_mapped_status,
    v_title,
    v_body,
    jsonb_build_object(
      'screen', 'orders',
      'click_action', '/?screen=orders',
      'order_id', coalesce(v_order_text, ''),
      'status', v_mapped_status,
      'status_raw', v_status
    ),
    'orders_status_trigger',
    'push_customer',
    'queued'
  );

  return new;
end;
$$;

revoke all on function public.create_customer_notification_from_order_status() from public;
grant execute on function public.create_customer_notification_from_order_status() to service_role;

do $orders_tr$
begin
  if to_regclass('public.orders') is null then
    raise notice 'public.orders is missing; orders status notification trigger was not created.';
    return;
  end if;

  execute 'drop trigger if exists orders_customer_status_notify_tr on public.orders';
  execute '
    create trigger orders_customer_status_notify_tr
    after update of status on public.orders
    for each row
    when (new.status is distinct from old.status)
    execute function public.create_customer_notification_from_order_status()
  ';
end;
$orders_tr$;

create or replace function public.invoke_customer_fcm_retry_fallback(
  p_batch_limit integer default 100
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_config public.customer_fcm_dispatch_config%rowtype;
  v_headers jsonb := jsonb_build_object('Content-Type', 'application/json');
  v_auth_token text;
  v_batch_limit integer := greatest(1, least(coalesce(p_batch_limit, 100), 500));
begin
  select *
  into v_config
  from public.customer_fcm_dispatch_config
  where coalesce(is_enabled, true) = true
  limit 1;

  if coalesce(nullif(trim(v_config.function_url), ''), '') = '' then
    return;
  end if;

  v_auth_token := nullif(trim(coalesce(v_config.function_auth_token, '')), '');
  if v_auth_token is not null then
    v_headers := v_headers || jsonb_build_object(
      'Authorization',
      'Bearer ' || v_auth_token
    );
  end if;

  begin
    perform net.http_post(
      url := v_config.function_url,
      headers := v_headers,
      body := jsonb_build_object(
        'target', 'customer',
        'batch_limit', v_batch_limit,
        'fallback_mode', true
      )
    );
  exception
    when undefined_function then
      raise warning 'net.http_post is unavailable while invoking fallback queue_customer_fcm';
    when others then
      raise warning 'invoke_customer_fcm_retry_fallback failed: %', sqlerrm;
  end;
end;
$$;

revoke all on function public.invoke_customer_fcm_retry_fallback(integer) from public;
grant execute on function public.invoke_customer_fcm_retry_fallback(integer) to service_role;

do $cron$
declare
  v_job_id bigint;
begin
  if to_regnamespace('cron') is null then
    raise notice 'pg_cron is unavailable; fallback scheduler was not installed.';
    return;
  end if;

  begin
    for v_job_id in
      select jobid
      from cron.job
      where jobname = 'customer_fcm_retry_fallback_every_minute'
    loop
      perform cron.unschedule(v_job_id);
    end loop;
  exception
    when others then
      null;
  end;

  begin
    perform cron.schedule(
      'customer_fcm_retry_fallback_every_minute',
      '* * * * *',
      'select public.invoke_customer_fcm_retry_fallback(200);'
    );
  exception
    when undefined_function then
      raise notice 'pg_cron function is unavailable; fallback scheduler was not installed.';
  end;
end;
$cron$;
