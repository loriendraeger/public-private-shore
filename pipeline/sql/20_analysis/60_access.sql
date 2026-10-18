-- Access status per segment, in layers; each later layer overrides the earlier ones.
-- access_source records which layer set the final value; access_kind (park,
-- nature_reserve, path, street_end, railway, override, ...) and access_name (the park,
-- trail or street, if named; the note, for overrides) record why. At the end,
-- config/access_display.csv turns them into the text the map shows (access_label,
-- access_reason).
--   1. default    config/access_defaults.csv, by ownership class
--   2. osm        config/access_osm.csv, by OSM feature category near the segment
--   3. path       a public footpath or cycleway reaches public land that is still unknown
--   3b. owner     the parcel owner's name says it (config/access_owner_rules.csv): DNR land,
--                 parks -> open; prisons, golf courses, stormwater, highways -> none
--   3c. nearby    public land (or a parcel gap) next to an OSM park or nature area
--   4. street_end road right-of-way that meets the water
--   5. barrier    a railway cuts open or unknown shore off from the land
--   6. (fill)     a short unknown between two matching segments takes theirs,
--                 source, kind and name included
--   6b. no_evidence  anything still unknown: nothing public reaches it -> none
--   7. override   config/access_overrides.csv, hand-curated; always wins
--   8. display    access_label + access_reason from config/access_display.csv

DROP TABLE IF EXISTS analysis.access_defaults, analysis.access_osm,
    analysis.access_display, analysis.access_owner_rules;
CREATE TABLE analysis.access_defaults (class text PRIMARY KEY, access text NOT NULL, note text);
CREATE TABLE analysis.access_osm (category text PRIMARY KEY, access text NOT NULL,
                                  private_land text NOT NULL
                                      CHECK (private_land IN ('any', 'named', 'no')),
                                  note text);
\copy analysis.access_defaults FROM 'config/access_defaults.csv' WITH (FORMAT csv, HEADER true)
\copy analysis.access_osm FROM 'config/access_osm.csv' WITH (FORMAT csv, HEADER true)
CREATE TABLE analysis.access_display (
    priority int PRIMARY KEY, access text NOT NULL, access_source text NOT NULL,
    access_kind text NOT NULL, owner_class text NOT NULL,
    access_label text NOT NULL, reason text, reason_unnamed text, note text);
\copy analysis.access_display FROM 'config/access_display.csv' WITH (FORMAT csv, HEADER true)
CREATE TABLE analysis.access_owner_rules (
    priority int PRIMARY KEY, pattern text NOT NULL, access text NOT NULL,
    reason text NOT NULL, note text);
\copy analysis.access_owner_rules FROM 'config/access_owner_rules.csv' WITH (FORMAT csv, HEADER true)

ALTER TABLE analysis.shore_segments
    ADD COLUMN IF NOT EXISTS access text,
    ADD COLUMN IF NOT EXISTS access_source text,
    ADD COLUMN IF NOT EXISTS access_kind text,
    ADD COLUMN IF NOT EXISTS access_name text,
    ADD COLUMN IF NOT EXISTS access_label text,
    ADD COLUMN IF NOT EXISTS access_reason text;

-- 1. Default from class.
UPDATE analysis.shore_segments s
SET access = coalesce(d.access, 'unknown'), access_source = 'default',
    access_kind = NULL, access_name = NULL
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
           f.category AS kind, f.name
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
    SELECT DISTINCT ON (segment_id) segment_id, access, kind, name
    FROM evidence
    ORDER BY segment_id, array_position(ARRAY['open', 'none'], access), name IS NULL, kind, name
)
UPDATE analysis.shore_segments s
SET access = b.access, access_source = 'osm', access_kind = b.kind, access_name = b.name
FROM best b WHERE b.segment_id = s.segment_id;

-- 3. Shore paths: public land whose access is still unknown is open when a public
-- footpath, cycleway or pedestrian way comes within :path_access_distance_m. Publicly
-- owned land you can walk onto from a public way is public access; facilities that
-- aren't (utilities, schools) already default to none, so they never get here.
UPDATE analysis.shore_segments s
SET access = 'open', access_source = 'path', access_kind = 'path', access_name = p.name
FROM analysis.shore_segments s0
CROSS JOIN LATERAL (
    SELECT r.name FROM staging.osm_roads r
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

-- 3b. Owner names (decision 2026-10-18): where access is still unknown, the first rule
-- (by priority) whose regex matches the parcel owner's raw name decides. The reason is a
-- curated label ("Golf course", "State natural resources land (DNR)"), never the raw
-- name, which stays in the database.
UPDATE analysis.shore_segments s
SET access = r.access, access_source = 'owner', access_kind = 'owner', access_name = r.reason
FROM analysis.shore_segments s0
CROSS JOIN LATERAL (
    SELECT * FROM analysis.access_owner_rules r
    WHERE s0.owner1 ~* r.pattern ORDER BY r.priority LIMIT 1
) r
WHERE s.segment_id = s0.segment_id AND s0.access = 'unknown' AND s0.owner1 IS NOT NULL;

-- 3c. Next to a park or nature area (decision 2026-10-18): public land, or shore with
-- no parcel, still unknown, within :nearby_evidence_m of an OSM park or nature reserve
-- is open: the step-2 rule wants the feature to cover half the segment, which misses
-- park land the OSM outline stops just short of (Mandt Park, Cherokee Marsh units).
UPDATE analysis.shore_segments s
SET access = 'open', access_source = 'nearby', access_kind = 'nearby', access_name = f.name
FROM analysis.shore_segments s0
CROSS JOIN LATERAL (
    SELECT f.name FROM staging.osm_access_features f
    WHERE f.category IN ('park', 'nature_reserve')
      AND coalesce(f.access, '') NOT IN ('no', 'private', 'customers', 'members', 'permit')
      AND ST_DWithin(f.geom, s0.geom, :nearby_evidence_m)
    ORDER BY f.name IS NULL, f.geom <-> s0.geom LIMIT 1
) f
WHERE s.segment_id = s0.segment_id
  AND s0.access = 'unknown' AND s0.owner_class <> 'private';

-- 4. Street ends: public road right-of-way that meets the water. Wisconsin generally
-- treats these as public access (some are posted or vacated; use overrides for those).
-- Highways are the exception (decision 2026-10-18): right-of-way of a numbered route
-- (OSM ref: interstate, US, state or county trunk highway), mostly where it bridges a
-- creek or the Yahara, is public land with no access from land.
UPDATE analysis.shore_segments s
SET access = CASE WHEN r.ref IS NULL THEN 'open' ELSE 'none' END,
    access_source = 'street_end',
    access_kind = CASE WHEN r.ref IS NULL THEN 'street_end' ELSE 'highway' END,
    access_name = CASE WHEN r.ref IS NULL THEN r.name ELSE coalesce(r.name || ' (' || r.ref || ')', r.ref) END
FROM analysis.shore_segments s0
LEFT JOIN LATERAL (
    SELECT r.name, r.ref FROM staging.osm_roads r
    WHERE r.is_street AND ST_DWithin(r.geom, s0.geom, :row_road_distance_m)
    ORDER BY r.geom <-> s0.geom LIMIT 1
) r ON true
WHERE s.segment_id = s0.segment_id AND s0.owner_class = 'row';

-- 5. Barriers: open or unknown shore cut off from the land by a railway (unknown too:
-- however it was going to be decided, there's no land route). Segments shorter than
-- :barrier_min_length_m are left alone (slivers where a segment ends at the tracks).
-- Sample the segment every
-- 10 m. A point is blocked when it's within :rail_shore_m of the tracks (the land
-- between them and the water is railroad corridor; this also covers smoothing moving
-- the line a few meters either side of tracks laid on the shore; not near a rail
-- bridge, where the tracks cross the water rather than run along it and the shore at
-- the bridge end is reached from the side), or when a railway is
-- within :barrier_distance_m and every public way that close would have to cross it to
-- get there (the shortest line from the way to the point crosses the tracks). Points
-- with no way nearby at all don't count either way. Most points blocked -> none. The
-- case in point: Monona Bay along the John Nolen Drive causeway, where the tracks run
-- on the shore and the trail and the drive are on their far side.
-- Overrides (below) still win, for crossings OSM doesn't show.
WITH cand AS (
    SELECT s.segment_id, s.geom FROM analysis.shore_segments s
    WHERE s.access IN ('open', 'unknown') AND s.length_m >= :barrier_min_length_m
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
           (EXISTS (SELECT 1 FROM staging.osm_railways r
                    WHERE ST_DWithin(r.geom, p.geom, :rail_shore_m))
            AND NOT EXISTS (SELECT 1 FROM staging.osm_railways r
                            WHERE r.bridge AND ST_DWithin(r.geom, p.geom, 2 * :rail_shore_m)))
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
SET access = 'none', access_source = 'barrier', access_kind = 'railway', access_name = NULL
FROM cut_off c
WHERE s.segment_id = c.segment_id AND s.access_source <> 'override';

-- 6. Short unknowns between matching neighbors (decision 2026-10-18): a segment shorter
-- than :neighbor_fill_max_m that is still unknown (no owner, or access undecided) takes
-- the owner class, label and access of the segments at both its ends, when those two
-- agree on all three and are fully known. It also takes their access source, kind and name
-- (from the start-side neighbor if the two differ): it is part of that same stretch,
-- not a decision of its own. The short segment must be a gap (no parcel)
-- or already share their class: a city or town strip between two private lots is often
-- a public lake-access lot, and must not become private (it goes to manual review).
WITH ends AS (
    SELECT s.segment_id, a.owner_class, a.owner_label, a.access, a.access_source,
           a.access_kind, a.access_name,
           b.owner_label AS b_label, b.access AS b_access,
           b.owner_class AS b_owner_class
    FROM analysis.shore_segments s
    CROSS JOIN LATERAL (
        SELECT n.owner_class, n.owner_label, n.access, n.access_source, n.access_kind,
               n.access_name
        FROM analysis.shore_segments n
        WHERE n.shore_id = s.shore_id AND n.segment_id <> s.segment_id
          AND ST_DWithin(n.geom, ST_StartPoint(s.geom), 0.5)
        ORDER BY n.geom <-> ST_StartPoint(s.geom) LIMIT 1) a
    CROSS JOIN LATERAL (
        SELECT n.owner_class, n.owner_label, n.access FROM analysis.shore_segments n
        WHERE n.shore_id = s.shore_id AND n.segment_id <> s.segment_id
          AND ST_DWithin(n.geom, ST_EndPoint(s.geom), 0.5)
        ORDER BY n.geom <-> ST_EndPoint(s.geom) LIMIT 1) b
    WHERE s.length_m < :neighbor_fill_max_m
      AND (s.owner_class = 'unknown' OR s.access = 'unknown')
      AND (s.owner_class = 'unknown' OR s.owner_class = a.owner_class)
)
UPDATE analysis.shore_segments s
SET owner_class = e.owner_class, owner_label = e.owner_label, access = e.access,
    access_source = e.access_source, access_kind = e.access_kind, access_name = e.access_name
FROM ends e
WHERE s.segment_id = e.segment_id
  AND e.owner_class = e.b_owner_class AND e.owner_label = e.b_label AND e.access = e.b_access
  AND e.owner_class <> 'unknown' AND e.access <> 'unknown';

-- 6b. No evidence (decision 2026-10-18: zero unknowns): whatever is still unknown has no
-- park, path, street end, owner signal or neighbor that makes it public -> none. The
-- long ones go to the review list.
UPDATE analysis.shore_segments
SET access = 'none', access_source = 'no_evidence', access_kind = NULL, access_name = NULL
WHERE access = 'unknown';

-- 7. Manual overrides (config/access_overrides.csv; loaded and matched to segments in
-- 40_classify.sql, by parcel): rows that set an access always win.
UPDATE analysis.shore_segments s
SET access = o.access, access_source = 'override', access_kind = 'override', access_name = o.note
FROM analysis.override_targets t JOIN analysis.overrides o USING (override_id)
WHERE s.segment_id = t.segment_id AND o.access IS NOT NULL;

-- 8. Display text (config/access_display.csv): the first rule, by priority, matching
-- access, source, kind and owner class ('*' = any) gives the label and the reason line.
-- {name} in the reason is the access_name; without one, reason_unnamed is used.
UPDATE analysis.shore_segments s
SET access_label = d.access_label,
    access_reason = CASE WHEN s.access_name IS NOT NULL AND coalesce(d.reason, '') <> ''
                         THEN replace(d.reason, '{name}', s.access_name)
                         ELSE nullif(d.reason_unnamed, '') END
FROM analysis.shore_segments s0
CROSS JOIN LATERAL (
    SELECT * FROM analysis.access_display r
    WHERE r.access IN ('*', s0.access)
      AND r.access_source IN ('*', s0.access_source)
      AND r.access_kind IN ('*', coalesce(s0.access_kind, ''))
      AND r.owner_class IN ('*', s0.owner_class)
    ORDER BY r.priority LIMIT 1
) d
WHERE s.segment_id = s0.segment_id;
