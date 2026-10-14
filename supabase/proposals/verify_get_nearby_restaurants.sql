-- LOCAL OR STAGING ONLY — never run EXPLAIN ANALYZE against Production.
--
-- Preconditions:
--   1. A disposable database has representative managers, profiles, and
--      restaurant_locations rows, including an active manager without a
--      location. The no-location manager must not appear in either result.
--   2. Save the current function body as get_nearby_restaurants_baseline
--      before applying the proposal in that disposable database.
--   3. Use a fixed coordinate that is already represented by the fixture.
--   4. Keep the unique restaurant_locations(restaurant_id) constraint. The
--      proposal relies on it; duplicate locations are invalid schema state.

begin read only;

-- Contract and authorization checks. All values must be true.
select
  has_function_privilege(
    'anon',
    'public.get_nearby_restaurants(double precision, double precision, text)',
    'execute'
  ) as anon_can_execute,
  has_function_privilege(
    'authenticated',
    'public.get_nearby_restaurants(double precision, double precision, text)',
    'execute'
  ) as authenticated_can_execute,
  not exists (
    select 1
    from public.restaurant_locations
    group by restaurant_id
    having count(*) > 1
  ) as location_cardinality_is_unique;

-- Result equivalence: this must return zero rows.  :matching_search must
-- match an already-existing fixture name; the third case covers the empty
-- search normalization that the function performs.  Run this matrix with a
-- fixture whose local time is both inside and outside an opening window (and,
-- when represented, an overnight window).
--
-- A manager without a location must be absent from both calls.  The direct
-- join and the old inner LATERAL join are equivalent only while the checked
-- unique restaurant_locations(restaurant_id) invariant holds.
with test_cases(label, lat, lng, search) as (
  values
    ('null-search', :lat::double precision, :lng::double precision, null::text),
    ('matching-search', :lat::double precision, :lng::double precision, :matching_search::text),
    ('empty-search', :lat::double precision, :lng::double precision, '   '::text)
), differences as (
  (
    select 'baseline_only' as direction, c.label, b.*
    from test_cases c
    cross join lateral public.get_nearby_restaurants_baseline(c.lat, c.lng, c.search) b
    except all
    select 'baseline_only' as direction, c.label, p.*
    from test_cases c
    cross join lateral public.get_nearby_restaurants(c.lat, c.lng, c.search) p
  )

  union all

  (
    select 'proposed_only' as direction, c.label, p.*
    from test_cases c
    cross join lateral public.get_nearby_restaurants(c.lat, c.lng, c.search) p
    except all
    select 'proposed_only' as direction, c.label, b.*
    from test_cases c
    cross join lateral public.get_nearby_restaurants_baseline(c.lat, c.lng, c.search) b
  )
)
select * from differences order by label, direction, restaurant_id;

-- Inspect the runtime and buffer use only in that disposable environment.
explain (analyze, buffers, verbose)
select * from public.get_nearby_restaurants(:lat, :lng, :search);

rollback;
