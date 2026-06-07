begin;

create extension if not exists pgcrypto with schema extensions;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

create or replace function public.current_security_actor_role()
returns text
language plpgsql
stable
as $$
begin
  return lower(
    coalesce(
      nullif(trim(auth.jwt() ->> 'role'), ''),
      nullif(trim(current_setting('request.jwt.claim.role', true)), ''),
      current_user,
      'authenticated'
    )
  );
end;
$$;

create or replace function public.is_elevated_security_actor(
  p_user_id uuid default auth.uid()
)
returns boolean
language plpgsql
stable
as $$
declare
  v_claim_role text := lower(coalesce(auth.jwt() ->> 'role', ''));
  v_app_role text := lower(
    coalesce(
      auth.jwt() -> 'app_metadata' ->> 'role',
      auth.jwt() -> 'user_metadata' ->> 'role',
      ''
    )
  );
begin
  if v_claim_role in ('service_role', 'supabase_admin', 'postgres') then
    return true;
  end if;

  if v_app_role in ('admin', 'owner', 'security_admin', 'super_admin', 'ops_admin') then
    return true;
  end if;

  return false;
end;
$$;

create or replace function public.log_security_metric(
  p_metric_key text,
  p_metric_value integer default 1,
  p_module text default 'security',
  p_user_id uuid default auth.uid(),
  p_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := nullif(trim(p_metric_key), '');
begin
  if v_key is null then
    return;
  end if;

  if to_regclass('public.security_metrics') is not null then
    insert into public.security_metrics (
      metric_key,
      metric_value,
      module,
      user_id,
      payload
    )
    values (
      v_key,
      greatest(coalesce(p_metric_value, 1), 1),
      coalesce(nullif(trim(p_module), ''), 'security'),
      p_user_id,
      coalesce(p_payload, '{}'::jsonb)
    );
  end if;

  if to_regclass('public.customer_stability_metrics') is not null then
    insert into public.customer_stability_metrics (
      user_id,
      metric_key,
      metric_value,
      module,
      payload
    )
    values (
      p_user_id,
      v_key,
      greatest(coalesce(p_metric_value, 1), 1),
      coalesce(nullif(trim(p_module), ''), 'security'),
      coalesce(p_payload, '{}'::jsonb)
    );
  end if;
exception
  when others then
    return;
end;
$$;

create table if not exists public.customer_sessions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_fingerprint text not null,
  refresh_token_hash text,
  session_id text,
  app_version text,
  ip_info text,
  suspicious_score integer not null default 0 check (suspicious_score >= 0),
  trust_score integer not null default 100,
  requires_reauth boolean not null default false,
  ip_hash text,
  geo_info jsonb not null default '{}'::jsonb,
  revoked_at timestamptz,
  is_active boolean not null default true,
  last_seen_at timestamptz not null default timezone('utc', now()),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  unique (user_id, device_fingerprint)
);

create table if not exists public.security_runtime_config (
  id boolean primary key default true check (id = true),
  rpc_signature_secret text not null,
  audit_signature_secret text not null,
  security_event_secret text not null,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.revoked_sessions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id text,
  device_fingerprint text,
  revoke_reason text not null,
  revoked_by uuid references auth.users(id) on delete set null,
  global_revoke boolean not null default false,
  requires_reauth boolean not null default true,
  propagate_realtime boolean not null default true,
  cache_bust_token text not null default encode(extensions.gen_random_bytes(16), 'hex'),
  metadata jsonb not null default '{}'::jsonb,
  revoked_at timestamptz not null default timezone('utc', now()),
  expires_at timestamptz,
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.suspicious_sessions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id text,
  device_fingerprint text,
  ip_info text,
  geo_info jsonb not null default '{}'::jsonb,
  anomaly_type text not null,
  trust_score integer not null default 0,
  risk_score integer not null default 0,
  requires_reauth boolean not null default true,
  force_logout boolean not null default false,
  status text not null default 'open'
    check (status in ('open', 'investigating', 'mitigated', 'closed')),
  metadata jsonb not null default '{}'::jsonb,
  detected_at timestamptz not null default timezone('utc', now()),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create index if not exists customer_sessions_user_active_idx
  on public.customer_sessions (user_id, is_active, last_seen_at desc);

create index if not exists customer_sessions_suspicious_idx
  on public.customer_sessions (suspicious_score desc, updated_at desc);

create index if not exists customer_sessions_user_session_idx
  on public.customer_sessions (user_id, session_id)
  where session_id is not null;

create index if not exists revoked_sessions_user_revoked_idx
  on public.revoked_sessions (user_id, revoked_at desc);

create index if not exists revoked_sessions_user_session_idx
  on public.revoked_sessions (user_id, session_id)
  where session_id is not null;

create index if not exists revoked_sessions_user_device_idx
  on public.revoked_sessions (user_id, device_fingerprint)
  where device_fingerprint is not null;

create index if not exists suspicious_sessions_user_detected_idx
  on public.suspicious_sessions (user_id, detected_at desc);

create index if not exists suspicious_sessions_status_idx
  on public.suspicious_sessions (status, detected_at desc);

insert into public.security_runtime_config (
  id,
  rpc_signature_secret,
  audit_signature_secret,
  security_event_secret
)
values (
  true,
  encode(extensions.gen_random_bytes(32), 'hex'),
  encode(extensions.gen_random_bytes(32), 'hex'),
  encode(extensions.gen_random_bytes(32), 'hex')
)
on conflict (id) do nothing;

do $repair_triggers$
begin
  if not exists (
    select 1 from pg_trigger
    where tgname = 'customer_sessions_set_updated_at'
      and tgrelid = 'public.customer_sessions'::regclass
      and not tgisinternal
  ) then
    create trigger customer_sessions_set_updated_at
    before update on public.customer_sessions
    for each row
    execute function public.set_updated_at();
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgname = 'security_runtime_config_set_updated_at'
      and tgrelid = 'public.security_runtime_config'::regclass
      and not tgisinternal
  ) then
    create trigger security_runtime_config_set_updated_at
    before update on public.security_runtime_config
    for each row
    execute function public.set_updated_at();
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgname = 'suspicious_sessions_set_updated_at'
      and tgrelid = 'public.suspicious_sessions'::regclass
      and not tgisinternal
  ) then
    create trigger suspicious_sessions_set_updated_at
    before update on public.suspicious_sessions
    for each row
    execute function public.set_updated_at();
  end if;
end;
$repair_triggers$;

alter table public.customer_sessions enable row level security;
alter table public.revoked_sessions enable row level security;
alter table public.suspicious_sessions enable row level security;
alter table public.security_runtime_config enable row level security;

do $repair_policies$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'customer_sessions'
      and policyname = 'customer_sessions_select_own'
  ) then
    create policy "customer_sessions_select_own"
    on public.customer_sessions
    for select
    to authenticated
    using (auth.uid() = user_id);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'customer_sessions'
      and policyname = 'customer_sessions_insert_own'
  ) then
    create policy "customer_sessions_insert_own"
    on public.customer_sessions
    for insert
    to authenticated
    with check (auth.uid() = user_id);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'customer_sessions'
      and policyname = 'customer_sessions_update_own'
  ) then
    create policy "customer_sessions_update_own"
    on public.customer_sessions
    for update
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'customer_sessions'
      and policyname = 'customer_sessions_service_role_all'
  ) then
    create policy "customer_sessions_service_role_all"
    on public.customer_sessions
    for all
    to service_role
    using (true)
    with check (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'revoked_sessions'
      and policyname = 'revoked_sessions_select_own'
  ) then
    create policy "revoked_sessions_select_own"
    on public.revoked_sessions
    for select
    to authenticated
    using (user_id = auth.uid());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'revoked_sessions'
      and policyname = 'revoked_sessions_service_role_all'
  ) then
    create policy "revoked_sessions_service_role_all"
    on public.revoked_sessions
    for all
    to service_role
    using (true)
    with check (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'suspicious_sessions'
      and policyname = 'suspicious_sessions_select_own'
  ) then
    create policy "suspicious_sessions_select_own"
    on public.suspicious_sessions
    for select
    to authenticated
    using (user_id = auth.uid());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'suspicious_sessions'
      and policyname = 'suspicious_sessions_insert_own'
  ) then
    create policy "suspicious_sessions_insert_own"
    on public.suspicious_sessions
    for insert
    to authenticated
    with check (user_id = auth.uid());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'suspicious_sessions'
      and policyname = 'suspicious_sessions_service_role_all'
  ) then
    create policy "suspicious_sessions_service_role_all"
    on public.suspicious_sessions
    for all
    to service_role
    using (true)
    with check (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'security_runtime_config'
      and policyname = 'security_runtime_config_service_role_all'
  ) then
    create policy "security_runtime_config_service_role_all"
    on public.security_runtime_config
    for all
    to service_role
    using (true)
    with check (true);
  end if;
end;
$repair_policies$;

revoke all on table public.security_runtime_config from public, anon, authenticated;
grant select, insert, update on table public.customer_sessions to authenticated;
grant select, insert, update, delete on table public.customer_sessions to service_role;
grant select on table public.revoked_sessions to authenticated;
grant select, insert, update, delete on table public.revoked_sessions to service_role;
grant select, insert on table public.suspicious_sessions to authenticated;
grant select, insert, update, delete on table public.suspicious_sessions to service_role;
grant select, update on table public.security_runtime_config to service_role;

create or replace function public.revoke_user_sessions(
  p_user_id uuid default auth.uid(),
  p_reason text default 'security_revocation',
  p_revoked_by uuid default auth.uid(),
  p_global_revoke boolean default true,
  p_session_id text default null,
  p_device_fingerprint text default null,
  p_requires_reauth boolean default true,
  p_propagate_realtime boolean default true,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_revocation_id uuid;
  v_user_id uuid := p_user_id;
begin
  if v_user_id is null then
    raise exception 'user_id_required' using errcode = '22023';
  end if;

  if auth.uid() is not null and auth.uid() <> v_user_id and not public.is_elevated_security_actor(auth.uid()) then
    raise exception 'insufficient_privileges_for_revocation' using errcode = '42501';
  end if;

  insert into public.revoked_sessions (
    user_id,
    session_id,
    device_fingerprint,
    revoke_reason,
    revoked_by,
    global_revoke,
    requires_reauth,
    propagate_realtime,
    metadata,
    revoked_at,
    expires_at,
    created_at
  )
  values (
    v_user_id,
    nullif(trim(coalesce(p_session_id, '')), ''),
    nullif(trim(coalesce(p_device_fingerprint, '')), ''),
    coalesce(nullif(trim(p_reason), ''), 'security_revocation'),
    p_revoked_by,
    coalesce(p_global_revoke, true),
    coalesce(p_requires_reauth, true),
    coalesce(p_propagate_realtime, true),
    coalesce(p_metadata, '{}'::jsonb),
    timezone('utc', now()),
    timezone('utc', now()) + interval '7 days',
    timezone('utc', now())
  )
  returning id into v_revocation_id;

  if coalesce(p_global_revoke, true) then
    update public.customer_sessions
    set
      is_active = false,
      requires_reauth = coalesce(p_requires_reauth, true),
      revoked_at = timezone('utc', now()),
      updated_at = timezone('utc', now())
    where user_id = v_user_id
      and is_active = true;
  else
    update public.customer_sessions
    set
      is_active = false,
      requires_reauth = coalesce(p_requires_reauth, true),
      revoked_at = timezone('utc', now()),
      updated_at = timezone('utc', now())
    where user_id = v_user_id
      and is_active = true
      and (
        (p_session_id is not null and coalesce(session_id, '') = trim(p_session_id))
        or (p_device_fingerprint is not null and coalesce(device_fingerprint, '') = trim(p_device_fingerprint))
      );
  end if;

  perform public.log_security_metric(
    'token_revocations',
    1,
    'session_revocation',
    v_user_id,
    jsonb_build_object('revocation_id', v_revocation_id)
  );

  return v_revocation_id;
end;
$$;

create or replace function public.register_suspicious_session(
  p_user_id uuid default auth.uid(),
  p_session_id text default null,
  p_device_fingerprint text default null,
  p_ip_info text default null,
  p_geo_info jsonb default '{}'::jsonb,
  p_anomaly_type text default 'unknown_anomaly',
  p_trust_score integer default 0,
  p_risk_score integer default 0,
  p_requires_reauth boolean default true,
  p_force_logout boolean default false,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := p_user_id;
  v_id uuid;
  v_risk integer := greatest(0, least(coalesce(p_risk_score, 0), 100));
  v_trust integer := greatest(0, least(coalesce(p_trust_score, 0), 100));
begin
  if v_user_id is null then
    raise exception 'user_id_required' using errcode = '22023';
  end if;

  insert into public.suspicious_sessions (
    user_id,
    session_id,
    device_fingerprint,
    ip_info,
    geo_info,
    anomaly_type,
    trust_score,
    risk_score,
    requires_reauth,
    force_logout,
    metadata,
    detected_at,
    created_at,
    updated_at
  ) values (
    v_user_id,
    nullif(trim(coalesce(p_session_id, '')), ''),
    nullif(trim(coalesce(p_device_fingerprint, '')), ''),
    nullif(trim(coalesce(p_ip_info, '')), ''),
    coalesce(p_geo_info, '{}'::jsonb),
    coalesce(nullif(trim(p_anomaly_type), ''), 'unknown_anomaly'),
    v_trust,
    v_risk,
    coalesce(p_requires_reauth, true),
    coalesce(p_force_logout, false),
    coalesce(p_metadata, '{}'::jsonb),
    timezone('utc', now()),
    timezone('utc', now()),
    timezone('utc', now())
  ) returning id into v_id;

  update public.customer_sessions
  set
    suspicious_score = greatest(coalesce(suspicious_score, 0), least(100, coalesce(suspicious_score, 0) + greatest(1, v_risk / 10))),
    trust_score = least(coalesce(trust_score, 100), v_trust),
    requires_reauth = coalesce(p_requires_reauth, true),
    updated_at = timezone('utc', now())
  where user_id = v_user_id
    and (
      (p_session_id is not null and coalesce(session_id, '') = trim(p_session_id))
      or (p_device_fingerprint is not null and coalesce(device_fingerprint, '') = trim(p_device_fingerprint))
    );

  perform public.log_security_metric(
    'suspicious_sessions',
    1,
    'session_theft_detection',
    v_user_id,
    jsonb_build_object('risk_score', v_risk, 'suspicious_session_id', v_id)
  );

  if coalesce(p_force_logout, false) or v_risk >= 90 then
    perform public.revoke_user_sessions(
      v_user_id,
      'suspicious_session_auto_revoke',
      auth.uid(),
      false,
      p_session_id,
      p_device_fingerprint,
      true,
      true,
      jsonb_build_object('suspicious_session_id', v_id, 'risk_score', v_risk)
    );
  end if;

  return v_id;
end;
$$;

create or replace function public.check_session_revocation(
  p_session_id text default null,
  p_device_fingerprint text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_revoked boolean := false;
  v_reason text := 'ok';
  v_requires_reauth boolean := false;
begin
  if v_user_id is null then
    return jsonb_build_object(
      'is_valid', false,
      'reason', 'not_authenticated',
      'requires_reauth', true,
      'should_terminate_realtime', true
    );
  end if;

  if exists (
    select 1
    from public.revoked_sessions rs
    where rs.user_id = v_user_id
      and (rs.expires_at is null or rs.expires_at > timezone('utc', now()))
      and (
        rs.global_revoke = true
        or (p_session_id is not null and coalesce(rs.session_id, '') = trim(p_session_id))
        or (p_device_fingerprint is not null and coalesce(rs.device_fingerprint, '') = trim(p_device_fingerprint))
      )
  ) then
    v_revoked := true;
    v_reason := 'session_revoked';
    v_requires_reauth := true;
  end if;

  if not v_revoked and p_device_fingerprint is not null then
    if exists (
      select 1
      from public.customer_sessions cs
      where cs.user_id = v_user_id
        and cs.device_fingerprint = trim(p_device_fingerprint)
        and (
          cs.is_active = false
          or coalesce(cs.requires_reauth, false) = true
          or coalesce(cs.suspicious_score, 0) >= 8
        )
    ) then
      v_revoked := true;
      v_reason := 'session_security_policy';
      v_requires_reauth := true;
    end if;
  end if;

  if v_revoked then
    perform public.log_security_metric(
      'auth_channel_kills',
      1,
      'auth_revalidation',
      v_user_id,
      jsonb_build_object('reason', v_reason)
    );
  end if;

  return jsonb_build_object(
    'is_valid', not v_revoked,
    'reason', v_reason,
    'requires_reauth', v_requires_reauth,
    'should_terminate_realtime', v_revoked,
    'actor_role', public.current_security_actor_role()
  );
end;
$$;

revoke all on function public.log_security_metric(text, integer, text, uuid, jsonb) from public;
grant execute on function public.log_security_metric(text, integer, text, uuid, jsonb) to authenticated, service_role;
revoke all on function public.revoke_user_sessions(uuid, text, uuid, boolean, text, text, boolean, boolean, jsonb) from public;
grant execute on function public.revoke_user_sessions(uuid, text, uuid, boolean, text, text, boolean, boolean, jsonb) to authenticated, service_role;
revoke all on function public.register_suspicious_session(uuid, text, text, text, jsonb, text, integer, integer, boolean, boolean, jsonb) from public;
grant execute on function public.register_suspicious_session(uuid, text, text, text, jsonb, text, integer, integer, boolean, boolean, jsonb) to authenticated, service_role;
revoke all on function public.check_session_revocation(text, text) from public;
grant execute on function public.check_session_revocation(text, text) to authenticated, service_role;

commit;
