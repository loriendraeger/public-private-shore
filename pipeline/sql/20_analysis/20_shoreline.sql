-- Shoreline = the boundary of the in-scope water, as lines, labeled by waterbody.
--
-- In scope: every NAMED water polygon (lake, pond, polygon river; county or DNR name)
-- touching the study area. Unnamed water (mostly stormwater ponds) is out of scope.
--
-- 1. ST_Union ALL water near the in-scope polygons, named or not. Edges two water
--    polygons share (seams, e.g. Lake Wingra / Murphy Creek, or between the Yahara's
--    river reaches) dissolve: water touching water is not shore. Interior rings
--    (islands) survive, so island shores come for free.
-- 2. For each named waterbody (name + WBIC), keep the part of that boundary that bounds
--    it. A small buffer absorbs floating-point noise from the union; where two named
--    waterbodies meet (a river entering a lake) up to ~1 m is counted for both.
-- 3. Clip to the study area.
--
-- Islands (holes in the unioned water) are excluded: you need a boat to reach them, and
-- this is about access from land. Exception: islands an OSM road or path crosses onto
-- from outside (a bridge or causeway). analysis.islands records every island.

DROP TABLE IF EXISTS analysis.islands CASCADE;
CREATE TABLE analysis.islands AS
WITH in_scope AS (
    SELECT w.* FROM staging.water w, analysis.study_area sa
    WHERE w.name IS NOT NULL AND ST_Intersects(w.geom, sa.geom)
),
water_union AS (
    SELECT (ST_Dump(ST_Union(w.geom))).geom AS geom
    FROM staging.water w
    WHERE EXISTS (SELECT 1 FROM in_scope s WHERE ST_DWithin(w.geom, s.geom, 0.5))
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

DROP TABLE IF EXISTS analysis.shoreline CASCADE;
CREATE TABLE analysis.shoreline AS
-- MATERIALIZED: compute each step once. Inlined, the union is redone per waterbody.
WITH in_scope AS (
    SELECT w.* FROM staging.water w, analysis.study_area sa
    WHERE w.name IS NOT NULL AND ST_Intersects(w.geom, sa.geom)
),
water_union AS MATERIALIZED (
    SELECT ST_Union(w.geom) AS geom
    FROM staging.water w
    WHERE EXISTS (SELECT 1 FROM in_scope s WHERE ST_DWithin(w.geom, s.geom, 0.5))
),
rings AS MATERIALIZED (
    SELECT r.path[1] AS ring_no, r.geom AS ring
    FROM (SELECT (ST_Dump(geom)).geom AS geom FROM water_union) u,
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
    -- One row per named waterbody; e.g. the Yahara is 16 polygons but one WBIC.
    SELECT name, wbic, ST_Buffer(ST_Union(geom), 0.5) AS zone
    FROM in_scope GROUP BY name, wbic
),
lines AS (
    SELECT wb.name, wb.wbic,
           (ST_Dump(ST_LineMerge(ST_Intersection(
               ST_Intersection(b.geom, wb.zone),
               (SELECT geom FROM analysis.study_area)
           )))).geom AS geom
    FROM waterbodies wb
    JOIN boundary b ON ST_Intersects(b.geom, wb.zone)
)
SELECT
    row_number() OVER () AS shore_id,
    name AS waterbody,
    wbic,
    geom::geometry(LineString, :crs) AS geom
FROM lines
WHERE ST_GeometryType(geom) = 'ST_LineString'
  AND ST_Length(geom) > :sample_step_m;   -- slivers from the buffer intersection

ALTER TABLE analysis.shoreline ADD PRIMARY KEY (shore_id);
CREATE INDEX ON analysis.shoreline USING gist (geom);
