-- Access status per segment, in layers; each later layer overrides the earlier ones.
-- access_source records which layer set the final value.
--   1. default    config/access_defaults.csv, by ownership class
--   2. osm        config/access_osm.csv, by OSM feature category near the segment
--   3. path       a public footpath or cycleway reaches public land that is still unknown
--   4. street_end road right-of-way that meets the water
--   5. barrier    a railway cuts open shore off from the land
--   6. override   config/access_overrides.csv, hand-curated; always wins

DROP TABLE IF EXISTS analysis.access_defaults, analysis.access_osm, analysis.access_overrides;
CREATE TABLE analysis.access_defaults (class text PRIMARY KEY, access text NOT NULL, note text);
CREATE TABLE analysis.access_osm (category text PRIMARY KEY, access text NOT NULL,
                                  private_land text NOT NULL
                                      CHECK (private_land IN ('any', 'named', 'no')),
                                  note text);
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
-- access=* tag beats the category: no/private/customers/members/permit -> none (members-
-- or customers-only isn't public access; decision 2026-10-17).
-- When several features apply, the most open status wins. On private (or unknown-owner)
-- land, private_land says whether a category counts there: 'any', 'named' (only
-- features with a name or access=yes/permissive: unnamed parks on private parcels are
-- mostly HOA greens, unnamed slipways private launches) or 'no' (piers: private docks).
WITH evidence AS (
    SELECT s.segment_id,
           CASE WHEN f.access IN ('no', 'private', 'customers', 'members', 'permit') THEN 'none'
                ELSE o.access END AS access,
           f.category || coalesce(': ' || f.name, '') AS why
    FROM analysis.shore_segments s
    JOIN staging.osm_access_features f
      ON ST_DWithin(f.geom, s.geom, :access_evidence_distance_m)
    JOIN analysis.access_osm o ON o.category = f.category
    WHERE (s.owner_class NOT IN ('private', 'unknown') OR o.private_land = 'any'
           OR (o.private_land = 'named'
               AND (f.name IS NOT NULL OR f.access IN ('yes', 'permissive'))))
      AND (f.kind <> 'area'
       OR ST_Length(ST_Intersection(s.geom, ST_Buffer(f.geom, :access_evidence_distance_m)))
          >= 0.5 * s.length_m)
),
best AS (
    SELECT DISTINCT ON (segment_id) segment_id, access, why
    FROM evidence
    ORDER BY segment_id, array_position(ARRAY['open', 'none'], access), why
)
UPDATE analysis.shore_segments s
SET access = b.access, access_source = 'osm', access_note = b.why
FROM best b WHERE b.segment_id = s.segment_id;

-- 3. Shore paths: public land whose access is still unknown is open when a public
-- footpath, cycleway or pedestrian way comes within :path_access_distance_m. Publicly
-- owned land you can walk onto from a public way is public access; facilities that
-- aren't (utilities, schools) already default to none, so they never get here.
UPDATE analysis.shore_segments s
SET access = 'open', access_source = 'path', access_note = 'path: ' || p.why
FROM analysis.shore_segments s0
CROSS JOIN LATERAL (
    SELECT coalesce(r.name, r.highway) AS why FROM staging.osm_roads r
    WHERE r.highway IN ('footway', 'path', 'cycleway', 'bridleway', 'pedestrian', 'steps')
      AND coalesce(r.access, '') NOT IN ('no', 'private', 'customers', 'members', 'permit')
      AND ST_DWithin(r.geom, s0.geom, :path_access_distance_m)
      -- Not across the tracks: the barrier step would undo it anyway, and the next
      -- path along may be the real way in.
      AND NOT EXISTS (SELECT 1 FROM staging.osm_railways t
                      WHERE ST_Intersects(t.geom, ST_ShortestLine(r.geom, s0.geom)))
    ORDER BY r.geom <-> s0.geom LIMIT 1
) p
WHERE s.segment_id = s0.segment_id
  AND s0.access = 'unknown' AND s0.owner_class NOT IN ('private', 'unknown');

-- 4. Street ends: public road right-of-way that meets the water. Wisconsin generally
-- treats these as public access (some are posted or vacated; use overrides for those).
UPDATE analysis.shore_segments s
SET access = 'open', access_source = 'street_end',
    access_note = (SELECT 'street: ' || coalesce(r.name, r.highway) FROM staging.osm_roads r
                   WHERE r.is_street AND ST_DWithin(r.geom, s.geom, :row_road_distance_m)
                   ORDER BY r.geom <-> s.geom LIMIT 1)
WHERE s.owner_class = 'row';

-- 5. Barriers: open shore cut off from the land by a railway. Sample the segment every
-- 10 m. A point is blocked when it's within :rail_shore_m of the tracks (the land
-- between them and the water is railroad corridor; this also covers smoothing moving
-- the line a few meters either side of tracks laid on the shore), or when a railway is
-- within :barrier_distance_m and every public way that close would have to cross it to
-- get there (the shortest line from the way to the point crosses the tracks). Points
-- with no way nearby at all don't count either way. Most points blocked -> none. The
-- case in point: Monona Bay along the John Nolen Drive causeway, where the tracks run
-- on the shore and the trail and the drive are on their far side.
-- Overrides (below) still win, for crossings OSM doesn't show.
WITH cand AS (
    SELECT s.segment_id, s.geom FROM analysis.shore_segments s
    WHERE s.access = 'open'
      AND EXISTS (SELECT 1 FROM staging.osm_railways r
                  WHERE ST_DWithin(r.geom, s.geom, :barrier_distance_m))
),
pts AS (
    SELECT c.segment_id, d.geom
    FROM cand c
    CROSS JOIN LATERAL ST_Dump(ST_LineInterpolatePoints(
        c.geom, least(1.0, 10.0 / greatest(ST_Length(c.geom), 10.0)))) d
),
judged AS (
    SELECT p.segment_id,
           EXISTS (SELECT 1 FROM staging.osm_railways r
                   WHERE ST_DWithin(r.geom, p.geom, :rail_shore_m))
           OR (EXISTS (SELECT 1 FROM staging.osm_railways r
                       WHERE ST_DWithin(r.geom, p.geom, :barrier_distance_m))
               AND w.n_ways > 0 AND w.n_clear = 0) AS blocked
    FROM pts p
    CROSS JOIN LATERAL (
        SELECT count(*) AS n_ways,
               count(*) FILTER (WHERE NOT EXISTS (
                   SELECT 1 FROM staging.osm_railways r
                   WHERE ST_Intersects(r.geom, ST_ShortestLine(x.geom, p.geom)))) AS n_clear
        FROM staging.osm_roads x
        WHERE ST_DWithin(x.geom, p.geom, :barrier_distance_m)
          AND x.highway NOT IN ('motorway', 'motorway_link', 'trunk', 'trunk_link')
          AND coalesce(x.access, '') NOT IN ('no', 'private', 'customers', 'members', 'permit')
    ) w
),
cut_off AS (
    SELECT segment_id FROM judged GROUP BY segment_id
    HAVING avg(blocked::int) > 0.5
)
UPDATE analysis.shore_segments s
SET access = 'none', access_source = 'barrier',
    access_note = 'railway between the shore and the land'
FROM cut_off c
WHERE s.segment_id = c.segment_id AND s.access_source <> 'override';

-- 6. Manual overrides: each applies to the segment nearest its point, within 20 m.
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
