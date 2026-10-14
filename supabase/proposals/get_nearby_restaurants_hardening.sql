-- PROPOSAL ONLY — do not apply directly to Production.
--
-- The deployed schema makes restaurant_locations.restaurant_id unique.  The
-- deployed function nevertheless uses a lateral subquery that sorts locations
-- for every candidate manager.  This equivalent direct join removes that
-- unnecessary per-row sort while preserving the function contract, grants,
-- security-definer owner, result columns, visibility rules, and distance
-- calculation.
--
-- This is a small query-shape hardening only.  It does not cure a database-wide
-- statement timeout caused by lock or resource contention; validate it in a
-- disposable local or staging database using verify_get_nearby_restaurants.sql.

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
  with runtime as (
    select timezone('Africa/Cairo', now())::time as local_time
  ), candidate_restaurants as (
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
      rl.lat,
      rl.lng,
      6371000.0 * 2.0 * asin(sqrt(least(1.0, greatest(0.0,
        power(sin(radians(rl.lat - user_lat) / 2.0), 2)
        + cos(radians(user_lat)) * cos(radians(rl.lat))
          * power(sin(radians(rl.lng - user_lng) / 2.0), 2)
      )))) as distance_meters
    from public.managers as m
    join public.profiles as p
      on p.id = m.user_id
     and p.role = 'manager'
     and p.is_active is true
    join public.restaurant_locations as rl
      on rl.restaurant_id = m.restaurant_id
    cross join runtime
    where m.restaurant_id is not null
      and coalesce(m.is_paused, false) is false
      and m.service_radius_meters > 0
      and user_lat between -90.0 and 90.0
      and user_lng between -180.0 and 180.0
      and rl.lat between -90.0 and 90.0
      and rl.lng between -180.0 and 180.0
      and m.open_time is not null
      and m.close_time is not null
      and (
        (m.close_time > m.open_time
          and runtime.local_time >= m.open_time
          and runtime.local_time <= m.close_time)
        or
        (m.close_time < m.open_time
          and (runtime.local_time >= m.open_time or runtime.local_time <= m.close_time))
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
