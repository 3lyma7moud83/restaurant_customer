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

create table if not exists public.app_content_entries (
  id uuid primary key default gen_random_uuid(),
  entry_key text not null
    check (entry_key in (
      'support_settings',
      'privacy_policy',
      'security_policy',
      'app_settings'
    )),
  title text not null,
  content text not null,
  language text not null
    check (language in ('ar', 'en')),
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint app_content_entries_unique_key_lang unique (entry_key, language)
);

create index if not exists app_content_entries_active_idx
  on public.app_content_entries (entry_key, language, is_active);

drop trigger if exists app_content_entries_set_updated_at on public.app_content_entries;
create trigger app_content_entries_set_updated_at
before update on public.app_content_entries
for each row
execute function public.set_updated_at();

alter table public.app_content_entries enable row level security;

drop policy if exists "app_content_entries_select_active" on public.app_content_entries;
create policy "app_content_entries_select_active"
on public.app_content_entries
for select
to anon, authenticated
using (is_active = true);

do $$
declare
  v_entry_key_attnum int2;
  v_language_attnum int2;
begin
  select a.attnum
  into v_entry_key_attnum
  from pg_attribute a
  where a.attrelid = 'public.app_content_entries'::regclass
    and a.attname = 'entry_key'
    and not a.attisdropped;

  select a.attnum
  into v_language_attnum
  from pg_attribute a
  where a.attrelid = 'public.app_content_entries'::regclass
    and a.attname = 'language'
    and not a.attisdropped;

  if v_entry_key_attnum is null or v_language_attnum is null then
    raise exception
      'public.app_content_entries is missing entry_key/language columns required for ON CONFLICT';
  end if;

  if not exists (
    select 1
    from pg_constraint c
    where c.conrelid = 'public.app_content_entries'::regclass
      and c.contype in ('u', 'x')
      and c.conkey @> array[v_entry_key_attnum, v_language_attnum]::int2[]
      and c.conkey <@ array[v_entry_key_attnum, v_language_attnum]::int2[]
      and cardinality(c.conkey) = 2
  ) then
    alter table public.app_content_entries
      add constraint app_content_entries_entry_key_language_unique
      unique (entry_key, language);
  end if;
end
$$;

insert into public.app_content_entries (
  entry_key,
  title,
  content,
  language,
  is_active
)
values
  (
    'support_settings',
    'الدعم الفني',
    'نوفّر دعمًا فنيًا للمشكلات المتعلقة بالتطبيق والطلبات على مدار الأسبوع.

طرق التواصل:
- البريد الإلكتروني: support@delivery-mat3mk.com
- الهاتف: +20 100 000 0000
- ساعات العمل: يوميًا من 10:00 صباحًا حتى 10:00 مساءً

لخدمة أسرع، يرجى إرسال رقم الطلب ووصف مختصر للمشكلة وصورة إن توفرت.',
    'ar',
    true
  ),
  (
    'privacy_policy',
    'سياسة الخصوصية',
    'نلتزم بحماية خصوصية المستخدمين والبيانات الشخصية.

نجمع الحد الأدنى من البيانات اللازمة لتشغيل الخدمة مثل الاسم ورقم الهاتف وعنوان التوصيل.
تُستخدم البيانات لتحسين جودة الطلبات والدعم الفني ولا يتم بيعها أو مشاركتها لأغراض تسويقية خارجية.
يمكن للمستخدم طلب تعديل أو حذف بياناته وفق القوانين المنظمة لحماية البيانات.',
    'ar',
    true
  ),
  (
    'security_policy',
    'الحماية والأمان',
    'نطبق ضوابط أمان تشغيلية لحماية الحسابات والمعاملات داخل التطبيق.

تشمل إجراءات الأمان:
- مراقبة الأخطاء الفنية والأنشطة غير المعتادة
- تقليل الوصول إلى البيانات الحساسة
- مراجعة دورية لسجلات الأعطال والأمان

ننصح المستخدم بعدم مشاركة بيانات تسجيل الدخول أو رموز التحقق مع أي طرف.',
    'ar',
    true
  ),
  (
    'app_settings',
    'رقم الإصدار',
    'v1.0.0',
    'ar',
    true
  ),
  (
    'support_settings',
    'Technical Support',
    'We provide technical support for app and order-related issues throughout the week.

Contact channels:
- Email: support@delivery-mat3mk.com
- Phone: +20 100 000 0000
- Support hours: Daily from 10:00 AM to 10:00 PM

For faster resolution, include your order number, a short issue summary, and a screenshot when possible.',
    'en',
    true
  ),
  (
    'privacy_policy',
    'Privacy Policy',
    'We are committed to protecting user privacy and personal data.

We collect only the minimum data required to operate the service, such as name, phone number, and delivery address.
This data is used to fulfill orders, improve service quality, and provide support.
We do not sell personal data or share it for third-party marketing purposes.
Users can request data updates or deletion in accordance with applicable regulations.',
    'en',
    true
  ),
  (
    'security_policy',
    'Protection & Security',
    'We apply operational security controls to protect accounts and in-app transactions.

Security measures include:
- Monitoring technical errors and unusual behavior
- Restricting access to sensitive data
- Periodic review of security and incident logs

Users should never share login credentials or verification codes with anyone.',
    'en',
    true
  ),
  (
    'app_settings',
    'App Version',
    'v1.0.0',
    'en',
    true
  )
on conflict (entry_key, language)
do update
set
  title = excluded.title,
  content = excluded.content,
  is_active = excluded.is_active,
  updated_at = timezone('utc', now());
