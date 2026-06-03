do $checkout_cart_details$
begin
  if to_regclass('public.orders') is not null then
    execute 'alter table public.orders
      add column if not exists customer_name text,
      add column if not exists customer_phone text,
      add column if not exists address text,
      add column if not exists building_number text,
      add column if not exists apartment_number text,
      add column if not exists floor_number text,
      add column if not exists landmark text,
      add column if not exists notes text,
      add column if not exists latitude double precision,
      add column if not exists longitude double precision,
      add column if not exists address_details jsonb';
  end if;

  if to_regclass('public.order_items') is not null then
    execute 'alter table public.order_items
      add column if not exists quantity integer,
      add column if not exists notes text';

    if exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'order_items'
        and column_name = 'qty'
    ) then
      execute 'update public.order_items
        set quantity = coalesce(quantity, qty)
        where quantity is null';
    end if;
  end if;

  if to_regclass('public.customer_addresses') is not null then
    execute 'alter table public.customer_addresses
      add column if not exists full_address text,
      add column if not exists primary_address text,
      add column if not exists building_number text,
      add column if not exists house_apartment_no text,
      add column if not exists apartment_number text,
      add column if not exists floor_number text,
      add column if not exists landmark text,
      add column if not exists area text,
      add column if not exists additional_notes text,
      add column if not exists lat double precision,
      add column if not exists lng double precision';

    if exists (
      select 1 from information_schema.columns
      where table_schema = 'public'
        and table_name = 'customer_addresses'
        and column_name = 'primary_address'
    ) then
      execute 'update public.customer_addresses
        set full_address = coalesce(full_address, primary_address)
        where full_address is null';
    end if;

    if exists (
      select 1 from information_schema.columns
      where table_schema = 'public'
        and table_name = 'customer_addresses'
        and column_name = 'house_apartment_no'
    ) then
      execute 'update public.customer_addresses
        set building_number = coalesce(building_number, house_apartment_no)
        where building_number is null';
    end if;
  end if;
end;
$checkout_cart_details$;
