-- Tile layer `shore`: one feature per segment. This is the public data contract (see
-- site/src/lib/). Raw owner names (owner1) and parcel ids NEVER appear here.
--
-- kind = 'bank': shore along lakes and wide rivers (and narrow banks with no centerline,
--                flagged `narrow`).
-- kind = 'stream': the centerline of narrow water, standing in for both banks
--                (80_streams.sql). Ids are offset by 10,000,000 to stay unique.
-- water_class = 'named' (lakes, rivers, named ponds) or 'pond' (standalone water the
--                county and DNR don't name; 10_staging/30_hydro.sql).
DROP VIEW IF EXISTS export.shore;
CREATE VIEW export.shore AS
SELECT
    s.segment_id,
    'bank' AS kind,
    s.narrow,
    sl.water_class,
    s.waterbody,
    s.category,
    s.owner_class,
    s.owner_label,
    NULL::text AS other_bank_label,
    s.access,
    s.access_source,
    s.access_note,
    s.muni_name,
    s.muni_type,
    round(s.length_m::numeric, 1)::float AS length_m,
    ST_Transform(s.geom, 4326)::geometry(LineString, 4326) AS geom
FROM analysis.shore_segments s
JOIN analysis.shoreline sl USING (shore_id)
WHERE NOT s.replaced
UNION ALL
SELECT
    10000000 + stream_segment_id,
    'stream',
    true,
    water_class,
    waterbody,
    category,
    owner_class,
    owner_label,
    other_bank_label,
    access,
    access_source,
    access_note,
    muni_name,
    muni_type,
    round(length_m::numeric, 1)::float,
    ST_Transform(geom, 4326)::geometry(LineString, 4326)
FROM analysis.stream_segments;
