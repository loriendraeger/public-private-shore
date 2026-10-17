-- Access status per segment, in layers; each later layer overrides the earlier ones.
-- access_source records which layer set the final value.
--   1. default    config/access_defaults.csv, by ownership class
--   2. osm        config/access_osm.csv, by OSM feature category near the segment
--   3. street_end road right-of-way that meets the water
--   4. override   config/access_overrides.csv, hand-curated; always wins

DROP TABLE IF EXISTS analysis.access_defaults, analysis.access_osm, analysis.access_overrides;
CREATE TABLE analysis.access_defaults (class text PRIMARY KEY, access text NOT NULL, note text);
CREATE TABLE analysis.access_osm (category text PRIMARY KEY, access text NOT NULL,
                                  public_only boolean NOT NULL, note text);
CREATE TABLE analysis.access_overrides (lon float, lat float, access text NOT NULL, note text NOT NULL);
\copy analysis.access_defaults FROM 'config/access_defaults.csv' WITH (FORMAT csv, HEADER true)
\copy analysis.access_osm FROM 'config/access_osm.csv' WITH (FORMAT csv, HEADER true)
\copy analysis.access_overrides FROM 'config/access_overrides.csv' WITH (FORMAT csv, HEADER true)

ALTER TABLE analysis.shore_segments
    ADD COLUMN IF NOT EXISTS access text,
    ADD COLUMN IF NOT EXISTS access_source text,
    ADD COLUMN IF NOT EXISTS access_note text;

-- 1. Default from class.
UPDATE analysis.shore_segments s
SET access = coalesce(d.access, 'unknown'), access_source = 'default', access_note = NULL
FROM (SELECT DISTINCT owner_class FROM analysis.shore_segments) c
LEFT JOIN analysis.access_defaults d ON d.class = c.owner_class
WHERE s.owner_class = c.owner_class;

-- 2. OSM evidence. Areas (parks, beaches) must cover at least half the segment, within
-- :access_evidence_distance_m, so a house next to a park doesn't inherit the park's
-- access. Points and lines (slipways) only need to be that close. An explicit OSM
-- access=* tag beats the category: private/customers/members -> restricted, no -> none.
-- When several features apply, the most open status wins. Categories flagged
-- public_only (piers) count only on non-private land.
WITH evidence AS (
    SELECT s.segment_id,
           CASE WHEN f.access IN ('no') THEN 'none'
                WHEN f.access IN ('private', 'customers', 'members', 'permit') THEN 'restricted'
                ELSE o.access END AS access,
           f.category || coalesce(': ' || f.name, '') AS why
    FROM analysis.shore_segments s
    JOIN staging.osm_access_features f
      ON ST_DWithin(f.geom, s.geom, :access_evidence_distance_m)
    JOIN analysis.access_osm o ON o.category = f.category
    WHERE (NOT o.public_only OR s.owner_class NOT IN ('private', 'unknown'))
      AND (f.kind <> 'area'
       OR ST_Length(ST_Intersection(s.geom, ST_Buffer(f.geom, :access_evidence_distance_m)))
          >= 0.5 * s.length_m)
),
best AS (
    SELECT DISTINCT ON (segment_id) segment_id, access, why
    FROM evidence
    ORDER BY segment_id, array_position(ARRAY['open', 'restricted', 'none'], access), why
)
UPDATE analysis.shore_segments s
SET access = b.access, access_source = 'osm', access_note = b.why
FROM best b WHERE b.segment_id = s.segment_id;

-- 3. Street ends: public road right-of-way that meets the water. Wisconsin generally
-- treats these as public access (some are posted or vacated; use overrides for those).
UPDATE analysis.shore_segments s
SET access = 'open', access_source = 'street_end',
    access_note = (SELECT 'street: ' || coalesce(r.name, r.highway) FROM staging.osm_roads r
                   WHERE r.is_street AND ST_DWithin(r.geom, s.geom, :row_road_distance_m)
                   ORDER BY r.geom <-> s.geom LIMIT 1)
WHERE s.owner_class = 'row';

-- 4. Manual overrides: each applies to the segment nearest its point, within 20 m.
UPDATE analysis.shore_segments s
SET access = o.access, access_source = 'override', access_note = o.note
FROM analysis.access_overrides o
CROSS JOIN LATERAL (
    SELECT segment_id FROM analysis.shore_segments s2
    WHERE ST_DWithin(s2.geom, ST_Transform(ST_SetSRID(ST_MakePoint(o.lon, o.lat), 4326), :crs), 20)
    ORDER BY s2.geom <-> ST_Transform(ST_SetSRID(ST_MakePoint(o.lon, o.lat), 4326), :crs)
    LIMIT 1
) hit
WHERE s.segment_id = hit.segment_id;
