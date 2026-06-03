create extension if not exists pgcrypto;

alter table if exists public.system_errors
  add column if not exists screen text,
  add column if not exists action text,
  add column if not exists error_type text default 'unknown',
  add column if not exists severity text default 'high',
  add column if not exists error_code text default 'ERR-UNK-001',
  add column if not exists user_message text,
  add column if not exists developer_message text,
  add column if not exists raw_error text,
  add column if not exists stacktrace text,
  add column if not exists restaurant_id uuid,
  add column if not exists driver_id uuid,
  add column if not exists device text,
  add column if not exists os text,
  add column if not exists app_version text,
  add column if not exists internet_status text,
  add column if not exists fingerprint text,
  add column if not exists occurrences integer default 1,
  add column if not exists status text default 'open',
  add column if not exists is_resolved boolean default false;

update public.system_errors
set
  error_type = coalesce(nullif(error_type, ''), 'unknown'),
  severity = coalesce(nullif(severity, ''), 'high'),
  error_code = coalesce(nullif(error_code, ''), 'ERR-UNK-001'),
  user_message = coalesce(
    nullif(user_message, ''),
    'حدث خطأ في البرنامج. حاول مرة أخرى لاحقًا'
  ),
  developer_message = coalesce(
    nullif(developer_message, ''),
    nullif(error_message, ''),
    'unknown error'
  ),
  raw_error = coalesce(nullif(raw_error, ''), nullif(error_message, '')),
  stacktrace = coalesce(nullif(stacktrace, ''), nullif(stack_trace, '')),
  device = coalesce(nullif(device, ''), 'unknown'),
  os = coalesce(nullif(os, ''), 'unknown'),
  app_version = coalesce(nullif(app_version, ''), 'unknown'),
  internet_status = coalesce(nullif(internet_status, ''), 'unknown'),
  occurrences = greatest(coalesce(occurrences, 1), 1),
  status = coalesce(nullif(status, ''), 'open'),
  is_resolved = coalesce(is_resolved, false),
  fingerprint = coalesce(
    nullif(fingerprint, ''),
    encode(
      digest(
        coalesce(error_type, 'unknown') || '|' ||
        coalesce(module, 'unknown') || '|' ||
        coalesce(action, '-') || '|' ||
        coalesce(stacktrace, stack_trace, ''),
        'sha256'
      ),
      'hex'
    )
  );

alter table public.system_errors
  alter column error_type set default 'unknown',
  alter column severity set default 'high',
  alter column error_code set default 'ERR-UNK-001',
  alter column occurrences set default 1,
  alter column occurrences set not null,
  alter column status set default 'open',
  alter column is_resolved set default false;

create index if not exists idx_system_errors_created_at
  on public.system_errors (created_at desc);
create index if not exists idx_system_errors_type
  on public.system_errors (error_type);
create index if not exists idx_system_errors_severity
  on public.system_errors (severity);
create index if not exists idx_system_errors_screen
  on public.system_errors (screen);
create index if not exists idx_system_errors_code
  on public.system_errors (error_code);
create index if not exists idx_system_errors_fingerprint
  on public.system_errors (fingerprint);

create unique index if not exists idx_system_errors_open_fingerprint
  on public.system_errors (app_name, fingerprint)
  where is_resolved = false and fingerprint is not null;

drop policy if exists "allow system error inserts" on public.system_errors;
create policy "allow system error inserts"
on public.system_errors
for insert
to anon, authenticated
with check (app_name in ('customer_app', 'admin', 'manager', 'cashier', 'driver'));

drop policy if exists "allow system error select" on public.system_errors;
create policy "allow system error select"
on public.system_errors
for select
to anon, authenticated
using (app_name in ('customer_app', 'admin', 'manager', 'cashier', 'driver'));

drop policy if exists "allow system error updates" on public.system_errors;
create policy "allow system error updates"
on public.system_errors
for update
to anon, authenticated
using (app_name in ('customer_app', 'admin', 'manager', 'cashier', 'driver'))
with check (app_name in ('customer_app', 'admin', 'manager', 'cashier', 'driver'));
