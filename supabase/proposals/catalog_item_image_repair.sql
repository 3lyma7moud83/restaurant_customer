-- PROPOSAL ONLY — do not run against Production without approval.
--
-- The affected item points to a syntactically valid PNG whose pixels contain a
-- historic Postgrest error. Flutter correctly treats it as a successful image
-- decode, so a generic client-side fallback cannot safely identify it.
--
-- Preferred repair: upload a validated replacement image to a new immutable
-- Storage path, then use that path here. Keeping the expected current path in
-- the predicate prevents overwriting a later editorial correction.
--
-- Bind :item_id, :expected_bad_image_url and :replacement_image_url in an
-- approved administrative run. Do not bind an empty replacement path.
update public.items
set image_url = :replacement_image_url
where id = :item_id
  and image_url = :expected_bad_image_url;
