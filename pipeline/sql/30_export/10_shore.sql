-- Tile layer `shore`: one feature per segment. This is the public data contract (see
-- site/src/lib/). Raw owner names (owner1) and parcel ids NEVER appear here.
CREATE OR REPLACE VIEW export.shore AS
SELECT
    segment_id,
    waterbody,
    category,
    owner_class,
    owner_label,
    access,
    access_source,
    access_note,
    muni_name,
    muni_type,
    round(length_m::numeric, 1)::float AS length_m,
    ST_Transform(geom, 4326)::geometry(LineString, 4326) AS geom
FROM analysis.shore_segments;
