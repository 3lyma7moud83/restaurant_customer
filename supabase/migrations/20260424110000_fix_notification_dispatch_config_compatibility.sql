create extension if not exists pgcrypto;

create table if not exists public.notification_dispatch_config (
  id boolean primary key default true check (id = true),
  function_url text not null,
  function_auth_token text,
  auth_token text,
  is_enabled boolean not null default true,
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

alter table if exists public.notification_dispatch_config
  add column if not exists function_url text,
  add column if not exists function_auth_token text,
  add column if not exists auth_token text,
  add column if not exists is_enabled boolean,
  add column if not exists is_active boolean,
  add column if not exists created_at timestamptz,
  add column if not exists updated_at timestamptz;

update public.notification_dispatch_config
set
  function_auth_token = coalesce(function_auth_token, auth_token),
  auth_token = coalesce(auth_token, function_auth_token),
  is_enabled = coalesce(is_enabled, is_active, true),
  is_active = coalesce(is_active, is_enabled, true),
  created_at = coalesce(created_at, timezone('utc', now())),
  updated_at = coalesce(updated_at, timezone('utc', now()))
where true;

alter table if exists public.notification_dispatch_config
  alter column is_enabled set default true,
  alter column is_active set default true,
  alter column created_at set default timezone('utc', now()),
  alter column updated_at set default timezone('utc', now());

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
  v_enabled boolean := coalesce(p_is_enabled, true);
  v_id_is_boolean boolean := false;
  v_existing_id uuid;
begin
  if v_url is null then
    raise exception 'function_url_required' using errcode = '22023';
  end if;

  select coalesce(data_type = 'boolean', false)
  into v_id_is_boolean
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'notification_dispatch_config'
    and column_name = 'id'
  limit 1;

  if v_id_is_boolean then
    insert into public.notification_dispatch_config (
      id,
      function_url,
      function_auth_token,
      auth_token,
      is_enabled,
      is_active
    )
    values (
      true,
      v_url,
      v_token,
      v_token,
      v_enabled,
      v_enabled
    )
    on conflict (id)
    do update
      set function_url = excluded.function_url,
          function_auth_token = excluded.function_auth_token,
          auth_token = excluded.auth_token,
          is_enabled = excluded.is_enabled,
          is_active = excluded.is_active,
          updated_at = timezone('utc', now());

    return;
  end if;

  select id
  into v_existing_id
  from public.notification_dispatch_config
  order by updated_at desc nulls last, created_at desc nulls last
  limit 1;

  if v_existing_id is null then
    insert into public.notification_dispatch_config (
      id,
      function_url,
      function_auth_token,
      auth_token,
      is_enabled,
      is_active
    )
    values (
      gen_random_uuid(),
      v_url,
      v_token,
      v_token,
      v_enabled,
      v_enabled
    );
  else
    update public.notification_dispatch_config
    set
      function_url = v_url,
      function_auth_token = v_token,
      auth_token = v_token,
      is_enabled = v_enabled,
      is_active = v_enabled,
      updated_at = timezone('utc', now())
    where id = v_existing_id;
  end if;
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
  v_auth_token text;
  v_body jsonb;
begin
  if new.status <> 'pending' then
    return new;
  end if;

  select *
  into v_config
  from public.notification_dispatch_config
  where coalesce(is_enabled, is_active, true) = true
  order by updated_at desc nulls last, created_at desc nulls last
  limit 1;

  if coalesce(nullif(trim(v_config.function_url), ''), '') = '' then
    return new;
  end if;

  v_auth_token := nullif(
    trim(coalesce(v_config.function_auth_token, v_config.auth_token, '')),
    ''
  );
  if v_auth_token is not null then
    v_headers := v_headers || jsonb_build_object(
      'Authorization',
      'Bearer ' || v_auth_token
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
      raise warning 'net.http_post is unavailable while enqueuing notification %', new.id;
    when others then
      raise warning 'enqueue_notification_processing failed for notification %: %', new.id, sqlerrm;
  end;

  return new;
end;
$$;

revoke all on function public.enqueue_notification_processing() from public;
grant execute on function public.enqueue_notification_processing() to service_role;

drop trigger if exists notifications_dispatch_trigger on public.notifications;
drop trigger if exists notifications_enqueue_processing_on_insert on public.notifications;
drop trigger if exists notifications_enqueue_processing_on_update on public.notifications;

create trigger notifications_enqueue_processing_on_insert
after insert
on public.notifications
for each row
when (new.status = 'pending')
execute function public.enqueue_notification_processing();

create trigger notifications_enqueue_processing_on_update
after update of status
on public.notifications
for each row
when (new.status = 'pending' and old.status is distinct from new.status)
execute function public.enqueue_notification_processing();

drop function if exists public.dispatch_notification_trigger();
