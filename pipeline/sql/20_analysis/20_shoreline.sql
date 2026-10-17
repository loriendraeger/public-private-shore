-- Shoreline = the boundary of the in-scope water, as lines.
--
-- 1. Take the in-scope water polygons (:'waterbodies') plus every water polygon touching
--    them (e.g. the Murphy Creek polygon at Wingra's outlet).
-- 2. ST_Union them. Edges two water polygons share (seams) dissolve: water touching water
--    is not shore. Interior rings (islands) survive, so island shores come for free.
-- 3. Keep only the boundary that bounds the in-scope water itself, so the creek's own
--    banks aren't included. A small buffer absorbs floating-point noise from the union.
DROP TABLE IF EXISTS analysis.shoreline CASCADE;
CREATE TABLE analysis.shoreline AS
WITH in_scope AS (
    SELECT * FROM staging.water
    WHERE name = ANY (string_to_array(:'waterbodies', ','))
),
water_union AS (
    SELECT ST_Union(w.geom) AS geom
    FROM staging.water w
    WHERE EXISTS (SELECT 1 FROM in_scope s WHERE ST_DWithin(w.geom, s.geom, 0.5))
),
shore AS (
    SELECT (ST_Dump(ST_LineMerge(ST_Intersection(
               ST_Boundary(u.geom),
               (SELECT ST_Buffer(ST_Union(geom), 0.5) FROM in_scope)
           )))).geom AS geom
    FROM water_union u
)
SELECT
    row_number() OVER () AS shore_id,
    s.name AS waterbody,
    s.wbic,
    shore.geom::geometry(LineString, :crs) AS geom
FROM shore
-- Each line belongs to the in-scope waterbody it bounds.
CROSS JOIN LATERAL (
    SELECT name, wbic FROM in_scope ORDER BY in_scope.geom <-> shore.geom LIMIT 1
) s
WHERE ST_GeometryType(shore.geom) = 'ST_LineString'
  AND ST_Length(shore.geom) > :sample_step_m;   -- slivers from the buffer intersection

ALTER TABLE analysis.shoreline ADD PRIMARY KEY (shore_id);
CREATE INDEX ON analysis.shoreline USING gist (geom);
