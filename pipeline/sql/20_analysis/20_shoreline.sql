-- Shoreline = the boundary of the in-scope water, as lines, labeled by waterbody.
--
-- In scope: every water polygon with a water_class (10_staging/30_hydro.sql: named
-- water, and standalone ponds of at least :pond_min_area_m2) touching the study area.
--
-- 1. ST_Union ALL water near the in-scope polygons, named or not. Edges two water
--    polygons share (seams, e.g. Lake Wingra / Murphy Creek, or between the Yahara's
--    river reaches) dissolve: water touching water is not shore. Interior rings
--    (islands) survive, so island shores come for free.
-- 2. For each named waterbody (name + WBIC), keep the part of that boundary that bounds
--    it. A small buffer absorbs floating-point noise from the union; where two named
--    waterbodies meet (a river entering a lake) up to ~1 m is counted for both.
-- 3. Clip to the study area.
-- 4. Simplify and smooth (pipeline.toml shore_*): Visvalingam-Whyatt, densify, Chaikin,
--    then a tiny simplify to drop the collinear points the densifying left on straight
--    runs. Everything downstream (segments, lengths, the map) uses the smoothed line.
--
-- Islands (holes in the unioned water) are excluded: you need a boat to reach them, and
-- this is about access from land. Exception: islands an OSM road or path crosses onto
-- from outside (a bridge or causeway). analysis.islands records every island.
--
-- Rail causeways are excluded the same way (decision 2026-10-18): a strip of land
-- narrower than :causeway_max_width_m with water on both sides and a railway on it
-- (the Wisconsin & Southern across Monona Bay: 20 m wide, 600 m long) can only be
-- reached along the tracks, and its two "shores" are track bed. Found with the same
-- morphological opening as narrow water (25_narrow_water.sql), applied to land:
-- take the land within 1.5 x the width of the tracks, shrink it by half the width and
-- grow it back. Strips narrower than the width vanish; the vanished pieces carrying at
-- least :causeway_min_length_m of track are causeways. A wide causeway with a road and a
-- trail on it (John Nolen Drive) stays shore. analysis.rail_causeways records them.

-- In-scope water, and all water touching it (named or not), unioned once.
-- In-scope polygons are ST_Subdivide'd (pieces of <= 256 vertices) for the "touching"
-- test: ST_DWithin between whole polygons the size of Lake Mendota (~40k vertices) took
-- over a minute; between small indexed pieces it takes a fraction of a second.
DROP TABLE IF EXISTS analysis.in_scope_water CASCADE;
CREATE TABLE analysis.in_scope_water AS
SELECT w.* FROM staging.water w, analysis.study_area sa
WHERE w.name IS NOT NULL AND ST_Intersects(w.geom, sa.geom);

-- A table, not a CTE: the pieces need a spatial index.
DROP TABLE IF EXISTS analysis.in_scope_pieces CASCADE;
CREATE TABLE analysis.in_scope_pieces AS
SELECT ST_Subdivide(geom, 256) AS geom FROM analysis.in_scope_water;
CREATE INDEX ON analysis.in_scope_pieces USING gist (geom);
ANALYZE analysis.in_scope_pieces;

DROP TABLE IF EXISTS analysis.water_union CASCADE;
CREATE TABLE analysis.water_union AS
SELECT ST_Union(w.geom) AS geom
FROM staging.water w
WHERE EXISTS (SELECT 1 FROM analysis.in_scope_pieces p WHERE ST_DWithin(w.geom, p.geom, 0.5));

DROP TABLE IF EXISTS analysis.islands CASCADE;
CREATE TABLE analysis.islands AS
WITH water_union AS (
    SELECT (ST_Dump(geom)).geom AS geom FROM analysis.water_union
),
holes AS (
    SELECT r.geom
    FROM water_union u, LATERAL ST_DumpRings(u.geom) r
    WHERE r.path[1] > 0      -- ring 0 is the outer edge; the rest are holes = islands
)
SELECT
    row_number() OVER () AS island_id,
    h.geom::geometry(Polygon, :crs) AS geom,
    ST_Area(h.geom) AS area_m2,
    EXISTS (
        SELECT 1 FROM staging.osm_roads r
        WHERE ST_Intersects(r.geom, h.geom) AND NOT ST_Within(r.geom, h.geom)
    ) AS bridged
FROM holes h;
CREATE INDEX ON analysis.islands USING gist (geom);

DROP TABLE IF EXISTS analysis.rail_causeways CASCADE;
CREATE TABLE analysis.rail_causeways AS
WITH rails AS MATERIALIZED (
    SELECT ST_Union(r.geom) AS geom FROM staging.osm_railways r
    WHERE EXISTS (SELECT 1 FROM analysis.in_scope_pieces p
                  WHERE ST_DWithin(r.geom, p.geom, :causeway_max_width_m))
),
zone AS MATERIALIZED (
    SELECT (ST_Dump(ST_Buffer(geom, 1.5 * :causeway_max_width_m))).geom AS geom FROM rails
),
land AS MATERIALIZED (
    SELECT coalesce(ST_Difference(z.geom, (SELECT ST_Union(w.geom) FROM staging.water w
                                           WHERE ST_Intersects(w.geom, z.geom))),
                    z.geom) AS geom
    FROM zone z
),
narrow AS (
    SELECT (ST_Dump(ST_Difference(l.geom,
               ST_Buffer(ST_Buffer(l.geom, -:causeway_max_width_m / 2.0, 'quad_segs=4'),
                         :causeway_max_width_m / 2.0, 'quad_segs=4')))).geom AS geom
    FROM land l
)
SELECT row_number() OVER () AS causeway_id, n.geom::geometry(Polygon, :crs) AS geom,
       ST_Length(ST_Intersection(n.geom, r.geom)) AS track_m
FROM narrow n, rails r
WHERE ST_GeometryType(n.geom) = 'ST_Polygon'
  AND ST_Length(ST_Intersection(n.geom, r.geom)) >= :causeway_min_length_m;
CREATE INDEX ON analysis.rail_causeways USING gist (geom);

DROP TABLE IF EXISTS analysis.shoreline CASCADE;
CREATE TABLE analysis.shoreline AS
-- MATERIALIZED: compute each step once.
WITH rings AS MATERIALIZED (
    SELECT r.path[1] AS ring_no, r.geom AS ring
    FROM (SELECT (ST_Dump(geom)).geom AS geom FROM analysis.water_union) u,
         LATERAL ST_DumpRings(u.geom) r
),
boundary AS MATERIALIZED (
    -- Outer edges, plus the edges of bridged islands.
    SELECT ST_ExteriorRing(ring) AS geom
    FROM rings
    WHERE ring_no = 0
       OR EXISTS (SELECT 1 FROM analysis.islands i
                  WHERE i.bridged AND ST_Equals(i.geom, rings.ring))
),
waterbodies AS MATERIALIZED (
    -- One row per waterbody; e.g. the Yahara is 16 polygons but one WBIC. Unnamed
    -- ponds share a name, so they group by WBIC (or all together without one); the
    -- zone still traces each pond's own boundary.
    SELECT name, wbic, water_class, ST_Buffer(ST_Union(geom), 0.5) AS zone
    FROM analysis.in_scope_water GROUP BY name, wbic, water_class
),
lines AS (
    SELECT wb.name, wb.wbic, wb.water_class,
           (ST_Dump(ST_LineMerge(ST_Difference(
               ST_Intersection(ST_Intersection(b.geom, wb.zone),
                               (SELECT geom FROM analysis.study_area)),
               -- Shore along rail causeways; :rail_shore_m covers the boundary sitting
               -- a few meters off the causeway polygon's edge.
               (SELECT coalesce(ST_Union(ST_Buffer(c.geom, :rail_shore_m)),
                                ST_SetSRID('POLYGON EMPTY'::geometry, :crs))
                FROM analysis.rail_causeways c)
           )))).geom AS geom
    FROM waterbodies wb
    JOIN boundary b ON ST_Intersects(b.geom, wb.zone)
),
smoothed AS (
    SELECT name, wbic, water_class,
           ST_SimplifyVW(
               ST_ChaikinSmoothing(
                   ST_Segmentize(ST_SimplifyVW(geom, :shore_simplify_area_m2),
                                 :shore_smooth_max_edge_m),
                   :shore_smooth_iterations),
               0.01) AS geom
    FROM lines
    WHERE ST_GeometryType(geom) = 'ST_LineString'
)
SELECT
    row_number() OVER () AS shore_id,
    name AS waterbody,
    wbic,
    water_class,
    geom::geometry(LineString, :crs) AS geom
FROM smoothed
WHERE ST_GeometryType(geom) = 'ST_LineString'
  AND ST_Length(geom) > :sample_step_m    -- slivers from the buffer intersection
  -- stubs the causeway cut leaves where a causeway meets the mainland
  AND NOT (ST_Length(geom) < 2 * :rail_shore_m
           AND EXISTS (SELECT 1 FROM analysis.rail_causeways c
                       WHERE ST_DWithin(c.geom, smoothed.geom, :rail_shore_m + 1)));

ALTER TABLE analysis.shoreline ADD PRIMARY KEY (shore_id);
CREATE INDEX ON analysis.shoreline USING gist (geom);
