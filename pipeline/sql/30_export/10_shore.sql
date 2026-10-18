-- Tile layer `shore`: one feature per shore run (20_analysis/90_merge.sql). This is the
-- public data contract (see site/src/lib/). Raw owner names (owner1) and parcel ids
-- NEVER appear here.
--
-- segment_id = the run's id (the site calls runs segments). Runs are rebuilt on every
-- pipeline run, so ids aren't stable across runs.
-- kind = 'bank': shore along lakes and wide rivers (and narrow banks with no centerline,
--                flagged `narrow`).
-- kind = 'stream': the centerline of narrow water, standing in for both banks
--                (80_streams.sql). Ids are offset by 10,000,000.
-- water_class = 'named' (lakes, rivers, named ponds) or 'pond' (standalone water the
--                county and DNR don't name; 10_staging/30_hydro.sql).
DROP VIEW IF EXISTS export.shore;
CREATE VIEW export.shore AS
SELECT
    run_id AS segment_id,
    kind,
    narrow,
    water_class,
    waterbody,
    category,
    owner_class,
    owner_label,
    other_bank_label,
    access,
    access_source,
    access_label,
    access_reason,
    muni_name,
    muni_type,
    round(length_m::numeric, 1)::float AS length_m,
    ST_Transform(geom, 4326)::geometry(LineString, 4326) AS geom
FROM analysis.shore_runs;
