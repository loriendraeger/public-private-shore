-- AD HOC (not part of the pipeline). Run with ./review.sh.
-- Access review list as Markdown: the automatic decisions most worth a human look, each
-- with a link to the site framed on it (bbox + seg) and a Google Maps satellite link.
-- Kept to ~25 rows (decision 2026-10-18); thresholds below.
--   1. no_evidence runs >= 150 m: nothing public found, set to no access
--   2. owner-name rules that said no access, runs >= 800 m
--   3. shore with no parcel, opened because it's next to a park, runs >= 300 m
--   0. anything still unknown (should be none)
-- Earlier rounds (railway barriers; public strips between private lots; private land
-- with public access) were reviewed 2026-10-18 and aren't listed.
-- Reads export.shore, so ids are the ones the map draws. They change when segmentation
-- changes: regenerate the list after rerunning the pipeline.
WITH items AS (
    SELECT
        s.segment_id, s.kind, s.muni_name, s.waterbody, s.owner_label, s.owner_class,
        s.category, s.access, s.access_source, s.access_reason, s.length_m,
        CASE WHEN s.access = 'unknown' OR s.category = 'unknown' THEN '0. Still unknown'
             WHEN s.access_source = 'no_evidence' THEN '1. Nothing public found, set to no access (check)'
             WHEN s.access_source = 'owner' AND s.access = 'none' THEN '2. Owner name says no access, large (check)'
             ELSE '3. No parcel, open because it is next to a park (check)' END AS section,
        ST_Transform(ST_Expand(ST_Transform(s.geom, :crs), 100), 4326) AS box,
        ST_ClosestPoint(s.geom, ST_Centroid(s.geom)) AS mid,
        concat_ws('; ',
            (SELECT 'path ' || round(min(ST_Distance(x.geom, ST_Transform(s.geom, :crs)))) || ' m'
             FROM staging.osm_roads x
             WHERE x.highway IN ('footway', 'path', 'cycleway', 'bridleway', 'pedestrian', 'steps')
               AND ST_DWithin(x.geom, ST_Transform(s.geom, :crs), 150)),
            (SELECT coalesce(f.name, f.category) || ' ' || round(ST_Distance(f.geom, ST_Transform(s.geom, :crs))) || ' m'
             FROM staging.osm_access_features f
             WHERE f.category IN ('park', 'nature_reserve')
               AND ST_DWithin(f.geom, ST_Transform(s.geom, :crs), 150)
             ORDER BY f.geom <-> ST_Transform(s.geom, :crs) LIMIT 1)) AS hint
    FROM export.shore s
    WHERE s.access = 'unknown' OR s.category = 'unknown'
       OR (s.access_source = 'no_evidence' AND s.length_m >= 150)
       OR (s.access_source = 'owner' AND s.access = 'none' AND s.length_m >= 800)
       OR (s.access_source = 'nearby' AND s.owner_class = 'unknown' AND s.length_m >= 300)
),
lines AS (
    SELECT section, muni_name, length_m,
        format('| %s | %s | %s | %s | %s | %s m | [map](%s#/map?bbox=%s,%s,%s,%s&seg=%s&color=access) | [google](https://www.google.com/maps/@?api=1&map_action=map&center=%s,%s&zoom=%s&basemap=satellite) |',
            segment_id,
            coalesce(waterbody, ''),
            coalesce(owner_label, '') || ' (' || owner_class || ')',
            access || coalesce(' / ' || access_source, ''),
            coalesce(replace(access_reason, '|', '/'), '') || CASE WHEN kind = 'stream' THEN ' [centerline]' ELSE '' END
                || CASE WHEN hint <> '' THEN ' (nearest: ' || replace(hint, '|', '/') || ')' ELSE '' END,
            round(length_m),
            :'site',
            round(ST_XMin(box)::numeric, 4), round(ST_YMin(box)::numeric, 4),
            round(ST_XMax(box)::numeric, 4), round(ST_YMax(box)::numeric, 4),
            segment_id,
            round(ST_Y(mid)::numeric, 5), round(ST_X(mid)::numeric, 5),
            CASE WHEN length_m < 300 THEN 18 WHEN length_m < 1000 THEN 17
                 WHEN length_m < 3000 THEN 16 ELSE 15 END) AS line
    FROM items
),
groups AS (
    SELECT section, muni_name, sum(length_m) AS total_m, count(*) AS n,
           string_agg(line, E'\n' ORDER BY length_m DESC) AS rows
    FROM lines GROUP BY section, muni_name
)
SELECT format(E'# Access review\n\nGenerated %s from export.shore. Segment ids are only valid for this pipeline run.\nMap links open the local dev site (%s); start it with `cd site && npm run dev`.\n', now()::date, :'site')
UNION ALL
SELECT string_agg(
    format(E'\n## %s: %s (%s segments, %s km)\n\n| seg | water | owner | access / source | note | length | site | google |\n|---|---|---|---|---|---|---|---|\n%s',
           section, coalesce(muni_name, '(no municipality)'), n, round(total_m::numeric / 1000, 2), rows),
    '' ORDER BY section, total_m DESC)
FROM groups;
