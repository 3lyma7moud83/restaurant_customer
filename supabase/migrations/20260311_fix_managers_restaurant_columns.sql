alter table public.managers
  add column if not exists full_address text,
  add column if not exists location_address text,
  add column if not exists street_address text,
  add column if not exists street text,
  add column if not exists district text,
  add column if not exists city text,
  add column if not exists area text,
  add column if not exists governorate text;

update public.managers
set
  full_address = coalesce(full_address, address),
  location_address = coalesce(location_address, address),
  street_address = coalesce(street_address, address)
where
  full_address is null
  or location_address is null
  or street_address is null;
