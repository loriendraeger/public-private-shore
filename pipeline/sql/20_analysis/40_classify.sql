-- Ownership class + display label for each segment.
--   Owned segments: first matching rule in analysis.ownership_rules.
--   Gaps (no parcel within tolerance): 'row' when an OSM street is within
--   :row_road_distance_m (road right-of-way is unparceled in Dane County), else 'unknown'.

ALTER TABLE analysis.shore_segments
    ADD COLUMN IF NOT EXISTS owner_class text,
    ADD COLUMN IF NOT EXISTS owner_label text,
    ADD COLUMN IF NOT EXISTS rule_priority integer;

UPDATE analysis.shore_segments s
SET (owner_class, owner_label, rule_priority) = (
    SELECT r.class, r.label, r.priority FROM analysis.ownership_rules r
    WHERE s.owner1 ~ r.pattern
    ORDER BY r.priority LIMIT 1
)
WHERE s.owner1 IS NOT NULL;

-- '{municipality}' labels: find which municipality the owner string names, in either
-- the 'CITY OF MADISON ...' or the inverted 'MADISON, CITY OF' form. Longest place name
-- first, so a longer name wins over a shorter one it contains.
UPDATE analysis.shore_segments s
SET owner_label = coalesce((
    SELECT m.name
    FROM staging.municipalities m
    CROSS JOIN LATERAL (SELECT upper(split_part(m.name, ' of ', 1)) AS kind,
                               upper(substr(m.name, strpos(m.name, ' of ') + 4)) AS place) n
    WHERE s.owner1 LIKE n.kind || ' OF ' || n.place || '%'
       OR s.owner1 LIKE n.place || ', ' || n.kind || ' OF%'
    ORDER BY length(n.place) DESC LIMIT 1
), 'Municipal (other)')
WHERE s.owner_label = '{municipality}';

UPDATE analysis.shore_segments s
SET owner_class = CASE WHEN EXISTS (
        SELECT 1 FROM staging.osm_roads r
        WHERE r.is_street AND ST_DWithin(r.geom, s.geom, :row_road_distance_m))
    THEN 'row' ELSE 'unknown' END
WHERE s.owner1 IS NULL;

UPDATE analysis.shore_segments
SET owner_label = CASE owner_class WHEN 'row' THEN 'Road right-of-way' ELSE 'Unknown' END
WHERE owner1 IS NULL;

-- Hand-curated overrides (config/access_overrides.csv). Each row targets a parcel by its
-- statewide id (stateid): every shore segment adjacent to that parcel. Keyed to the
-- parcel, not a point on a segment, so it survives resegmentation (snap tolerance,
-- merging rules). Rows without a stateid fall back to the point (lon, lat): the
-- nearest segment within 20 m, for shore with no parcel. lon/lat on parcel rows only
-- say where it is, for people and QGIS.
-- A row may set the owner (owner_class, owner_label; applied here, before access) and/or
-- the access (applied last in 60_access.sql). Segments are per owner run, so a segment
-- that spans the parcel and a neighboring parcel with the same owner takes the override
-- along its whole length.
DROP TABLE IF EXISTS analysis.overrides, analysis.override_targets CASCADE;
CREATE TABLE analysis.overrides (
    stateid text, lon float, lat float, access text, owner_class text, owner_label text,
    note text NOT NULL);
\copy analysis.overrides FROM 'config/access_overrides.csv' WITH (FORMAT csv, HEADER true)
ALTER TABLE analysis.overrides ADD COLUMN override_id serial PRIMARY KEY;

CREATE TABLE analysis.override_targets AS
SELECT o.override_id, s.segment_id
FROM analysis.overrides o
JOIN staging.parcels p ON p.stateid = o.stateid
JOIN analysis.shore_segments s ON p.parcel_id = ANY (s.parcel_ids)
WHERE o.stateid IS NOT NULL
UNION
SELECT o.override_id, hit.segment_id
FROM analysis.overrides o
CROSS JOIN LATERAL (
    SELECT s.segment_id FROM analysis.shore_segments s
    WHERE ST_DWithin(s.geom, ST_Transform(ST_SetSRID(ST_MakePoint(o.lon, o.lat), 4326), :crs), 20)
    ORDER BY s.geom <-> ST_Transform(ST_SetSRID(ST_MakePoint(o.lon, o.lat), 4326), :crs)
    LIMIT 1
) hit
WHERE o.stateid IS NULL;

-- An override that matches no shore is stale (parcel gone, or no longer on the shore).
DO $$
DECLARE stale text;
BEGIN
    SELECT string_agg(coalesce(o.stateid, o.lon || ',' || o.lat), '; ') INTO stale
    FROM analysis.overrides o
    WHERE NOT EXISTS (SELECT 1 FROM analysis.override_targets t WHERE t.override_id = o.override_id);
    IF stale IS NOT NULL THEN
        RAISE WARNING 'access_overrides.csv rows matching no shore segment: %', stale;
    END IF;
END $$;

UPDATE analysis.shore_segments s
SET owner_class = o.owner_class, owner_label = coalesce(o.owner_label, s.owner_label)
FROM analysis.override_targets t JOIN analysis.overrides o USING (override_id)
WHERE s.segment_id = t.segment_id AND o.owner_class IS NOT NULL;
