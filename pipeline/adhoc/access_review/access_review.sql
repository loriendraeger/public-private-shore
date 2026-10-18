-- AD HOC (not part of the pipeline). Run with ./review.sh.
-- Access review list as Markdown: every segment the map shows that needs a human look
-- (railway barriers, to confirm; unknown access or category, to decide), each with a
-- link to the site framed on it (bbox + seg) and a Google Maps satellite link.
-- Reads export.shore, so segment ids are the ones the map draws. They change on every
-- pipeline run: regenerate the list after rerunning the pipeline.
WITH items AS (
    SELECT
        s.segment_id, s.kind, s.muni_name, s.waterbody, s.owner_label, s.owner_class,
        s.category, s.access, s.access_source, s.access_note, s.length_m,
        CASE WHEN s.access_source = 'barrier' THEN 'Railway barriers (confirm)'
             ELSE 'Unknown (decide)' END AS section,
        ST_Transform(ST_Expand(ST_Transform(s.geom, :crs), 100), 4326) AS box,
        ST_ClosestPoint(s.geom, ST_Centroid(s.geom)) AS mid
    FROM export.shore s
    WHERE s.access_source = 'barrier' OR s.access = 'unknown' OR s.category = 'unknown'
),
lines AS (
    SELECT section, muni_name, length_m,
        format('| %s | %s | %s | %s | %s | %s m | [map](%s#/map?bbox=%s,%s,%s,%s&seg=%s&color=access) | [google](https://www.google.com/maps/@?api=1&map_action=map&center=%s,%s&zoom=%s&basemap=satellite) |',
            segment_id,
            coalesce(waterbody, ''),
            coalesce(owner_label, '') || ' (' || owner_class || ')',
            access || coalesce(' / ' || access_source, ''),
            coalesce(replace(access_note, '|', '/'), '') || CASE WHEN kind = 'stream' THEN ' [centerline]' ELSE '' END,
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
