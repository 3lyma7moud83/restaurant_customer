begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

grant select, update on table public.system_errors to anon, authenticated;

create or replace function public.immutable_audit_chain_before_insert()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_previous_hash text;
  v_secret text;
  v_hash_input text;
begin
  select current_hash
  into v_previous_hash
  from public.immutable_audit_chain
  where chain_partition = new.chain_partition
  order by id desc
  limit 1;

  new.previous_hash := coalesce(v_previous_hash, repeat('0', 64));
  new.occurred_at := coalesce(new.occurred_at, timezone('utc', now()));

  v_hash_input := concat_ws(
    '|',
    new.previous_hash,
    coalesce(new.chain_partition, ''),
    coalesce(new.event_type, ''),
    coalesce(new.action, ''),
    coalesce(new.actor_user_id::text, ''),
    coalesce(new.actor_role, ''),
    coalesce(new.target_type, ''),
    coalesce(new.target_id, ''),
    coalesce(new.payload::text, '{}'),
    extract(epoch from new.occurred_at)::text
  );

  new.current_hash := encode(extensions.digest(v_hash_input, 'sha256'), 'hex');

  select audit_signature_secret
  into v_secret
  from public.security_runtime_config
  where id = true
  limit 1;

  if coalesce(v_secret, '') = '' then
    v_secret := new.current_hash;
  end if;

  new.signed_integrity := encode(
    extensions.hmac(new.current_hash, v_secret, 'sha256'),
    'hex'
  );
  new.created_at := coalesce(new.created_at, timezone('utc', now()));
  return new;
end;
$$;

create or replace function public.security_events_before_insert()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_previous_hash text;
  v_secret text;
  v_hash_input text;
begin
  select event_hash
  into v_previous_hash
  from public.security_events
  order by id desc
  limit 1;

  new.previous_event_hash := coalesce(v_previous_hash, repeat('0', 64));
  new.occurred_at := coalesce(new.occurred_at, timezone('utc', now()));
  new.severity := public.normalize_security_severity(new.severity);

  v_hash_input := concat_ws(
    '|',
    new.previous_event_hash,
    coalesce(new.event_key, ''),
    coalesce(new.severity, ''),
    coalesce(new.actor_user_id::text, ''),
    coalesce(new.actor_role, ''),
    coalesce(new.session_id, ''),
    coalesce(new.device_fingerprint, ''),
    coalesce(new.source_ip, ''),
    coalesce(new.event_payload::text, '{}'),
    coalesce(new.related_request_id, ''),
    coalesce(new.related_nonce, ''),
    extract(epoch from new.occurred_at)::text
  );

  new.event_hash := encode(extensions.digest(v_hash_input, 'sha256'), 'hex');

  select security_event_secret
  into v_secret
  from public.security_runtime_config
  where id = true
  limit 1;

  if coalesce(v_secret, '') = '' then
    v_secret := new.event_hash;
  end if;

  new.integrity_signature := encode(
    extensions.hmac(new.event_hash, v_secret, 'sha256'),
    'hex'
  );
  new.created_at := coalesce(new.created_at, timezone('utc', now()));
  return new;
end;
$$;

commit;
