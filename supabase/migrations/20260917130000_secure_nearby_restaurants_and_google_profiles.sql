-- Restaurant discovery is deliberately exposed only through this narrow RPC.
-- `profiles` remains private under its existing RLS policies.
drop function if exists public.get_nearby_restaurants(double precision, double precision);

create or replace function public.get_nearby_restaurants(
  user_lat double precision,
  user_lng double precision,
  search_text text default null
)
returns table(
  manager_id uuid,
  restaurant_id uuid,
  name text,
  image_url text,
  restaurant_type text,
  phone text,
  address text,
  full_address text,
  location_address text,
  street_address text,
  street text,
  district text,
  city text,
  area text,
  governorate text,
  service_radius_meters integer,
  is_paused boolean,
  open_time time without time zone,
  close_time time without time zone,
  lat double precision,
  lng double precision,
  distance_meters double precision
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with candidate_restaurants as (
    select
      m.user_id as manager_id,
      m.restaurant_id,
      m.name,
      m.image_url,
      m.restaurant_type,
      m.phone,
      m.address,
      m.full_address,
      m.location_address,
      m.street_address,
      m.street,
      m.district,
      m.city,
      m.area,
      m.governorate,
      m.service_radius_meters,
      m.is_paused,
      m.open_time,
      m.close_time,
      location.lat,
      location.lng,
      (
        6371000.0 * 2.0 * asin(
          sqrt(
            least(1.0, greatest(0.0,
              power(sin(radians(location.lat - user_lat) / 2.0), 2)
              + cos(radians(user_lat))
                * cos(radians(location.lat))
                * power(sin(radians(location.lng - user_lng) / 2.0), 2)
            ))
          )
        )
      ) as distance_meters
    from public.managers as m
    join public.profiles as p
      on p.id = m.user_id
     and p.role = 'manager'
     and p.is_active is true
    join lateral (
      select rl.lat, rl.lng
      from public.restaurant_locations as rl
      where rl.restaurant_id = m.restaurant_id
      order by rl.updated_at desc nulls last
      limit 1
    ) as location on true
    where m.restaurant_id is not null
      and coalesce(m.is_paused, false) is false
      and m.service_radius_meters > 0
      and user_lat between -90.0 and 90.0
      and user_lng between -180.0 and 180.0
      and location.lat between -90.0 and 90.0
      and location.lng between -180.0 and 180.0
      and m.open_time is not null
      and m.close_time is not null
      and (
        (m.close_time > m.open_time
          and timezone('Africa/Cairo', now())::time >= m.open_time
          and timezone('Africa/Cairo', now())::time <= m.close_time)
        or
        (m.close_time < m.open_time
          and (
            timezone('Africa/Cairo', now())::time >= m.open_time
            or timezone('Africa/Cairo', now())::time <= m.close_time
          ))
      )
      and (
        nullif(btrim(search_text), '') is null
        or m.name ilike '%' || btrim(search_text) || '%'
      )
  )
  select *
  from candidate_restaurants
  where distance_meters <= service_radius_meters
  order by distance_meters asc, name asc;
$$;

revoke all on function public.get_nearby_restaurants(double precision, double precision, text) from public;
grant execute on function public.get_nearby_restaurants(double precision, double precision, text) to anon, authenticated;

-- Google OAuth user creation must be idempotent and must not depend on a
-- client-side read of profiles. This trigger runs in the auth transaction.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  resolved_name text := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
    nullif(btrim(new.email), ''),
    'مستخدم جديد'
  );
begin
  insert into public.profiles (id, email, name, role, created_at)
  values (new.id, new.email, resolved_name, 'customer', now())
  on conflict (id) do update
    set email = coalesce(public.profiles.email, excluded.email),
        name = case
          when public.profiles.name is null or btrim(public.profiles.name) = ''
            then excluded.name
          else public.profiles.name
        end;

  insert into public.customers (id, name, email, created_at)
  values (new.id, resolved_name, new.email, now())
  on conflict (id) do update
    set email = coalesce(public.customers.email, excluded.email),
        name = case
          when public.customers.name is null or btrim(public.customers.name) = ''
            then excluded.name
          else public.customers.name
        end;

  return new;
end;
$$;
