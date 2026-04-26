alter table public.managers
  add column if not exists restaurant_type text;

comment on column public.managers.restaurant_type is
  'Restaurant category shown to customers (e.g. مطعم, كافيه, مشويات, بيتزا, برجر, حلويات).';

create index if not exists managers_restaurant_type_idx
  on public.managers (restaurant_type);
