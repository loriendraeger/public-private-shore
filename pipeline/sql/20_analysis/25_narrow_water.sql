-- Narrow water: where the in-scope water is narrower than :narrow_width_m, its two banks
-- collapse onto the stream centerline (80_streams.sql). This file decides WHERE.
--
-- The decision is made once, along the centerline, and smoothed; banks then take the
-- decision of the nearest centerline (30_shore_segments.sql). Deciding on each bank
-- separately made channels that hover near the threshold (the Yahara through Cherokee
-- Marsh) flicker between "two banks" and "one line" every few dozen meters, with gaps
-- and doubles where the banks and the centerline disagreed.
--
-- 1. analysis.stream_lines: Dane County stream centerlines in (or within half the narrow
--    width of) in-scope water, in the study area. Not clipped to the water exactly: on
--    6 m creeks the separately digitized centerline often strays a few meters outside.
-- 2. Width every :narrow_measure_step_m along each line = distance to the nearest
--    shoreline on the left + on the right (side = sign of the cross product of the line
--    direction and the vector to the shore point). No shore on a side within the search
--    radius = wide.
-- 3. Smooth: rolling median over :narrow_smoothing_m, so one wide bend or pool doesn't
--    break up a narrow reach. Then runs shorter than :narrow_min_run_m take their
--    neighbor's class.
-- 4. analysis.stream_steps: the lines every :sample_step_m, each with the class of the
--    nearest measurement.
--
-- Fallback where there is no centerline (marsh channels): morphological OPENING.
-- Shrink the water by half the width (negative buffer) and grow it back; channels
-- narrower than the width vanish and don't return. analysis.wide_water is the result.

DROP TABLE IF EXISTS analysis.water_parts CASCADE;
CREATE TABLE analysis.water_parts AS
SELECT row_number() OVER () AS part_id, d.geom::geometry(Polygon, :crs) AS geom
FROM (
    SELECT ST_Union(w.geom) AS geom FROM staging.water w
    WHERE EXISTS (SELECT 1 FROM analysis.shoreline s WHERE ST_DWithin(w.geom, s.geom, 1))
) u, LATERAL ST_Dump(u.geom) d;
CREATE INDEX ON analysis.water_parts USING gist (geom);

DROP TABLE IF EXISTS analysis.wide_water CASCADE;
CREATE TABLE analysis.wide_water AS
SELECT row_number() OVER () AS wide_id, d.geom::geometry(Polygon, :crs) AS geom
FROM analysis.water_parts wp,
     LATERAL ST_Dump(ST_Buffer(ST_Buffer(wp.geom, -:narrow_width_m / 2.0, 'quad_segs=4'),
                               :narrow_width_m / 2.0, 'quad_segs=4')) d;
CREATE INDEX ON analysis.wide_water USING gist (geom);

-- 1. Centerlines. Clip zone = the water plus half the narrow width. Buffering whole
-- lakes was the slow part, so buffer small ST_Subdivide pieces and union them back
-- (same shape, under a second). Clipping each line once against the unioned zone avoids
-- the slivers that per-piece clipping leaves where piece buffers overlap.
DROP TABLE IF EXISTS analysis.stream_zone CASCADE;
CREATE TABLE analysis.stream_zone AS
SELECT (ST_Dump(ST_Union(ST_Buffer(d.geom, :narrow_width_m / 2.0, 'quad_segs=4')))).geom AS geom
FROM analysis.water_parts wp, LATERAL ST_Subdivide(wp.geom, 256) d(geom);
CREATE INDEX ON analysis.stream_zone USING gist (geom);
ANALYZE analysis.stream_zone;

DROP TABLE IF EXISTS analysis.stream_lines CASCADE;
CREATE TABLE analysis.stream_lines AS
WITH lines AS MATERIALIZED (
    SELECT cs.fid, cs.name, ST_Transform(cs.geom, :crs) AS geom
    FROM raw.county_streams cs
    -- Not culverted / underground. coalesce: most lines have no dxflayer, and a NULL
    -- would make the whole condition NULL (= dropped).
    WHERE coalesce(cs.dxflayer, '') NOT ILIKE '%hidden%'
      AND coalesce(cs.hydtype, '') NOT ILIKE 'hidden%'
      -- cheap prefilter in the source CRS, using raw's spatial index
      -- (ST_Extent returns a box with no SRID; tag it before transforming)
      AND cs.geom && (SELECT ST_Transform(ST_SetSRID(ST_Expand(ST_Extent(geom), 100)::geometry, :crs),
                                   Find_SRID('raw', 'county_streams', 'geom'))
                      FROM analysis.water_parts)
),
dumped AS (
    SELECT l.fid, l.name,
           (ST_Dump(ST_LineMerge(ST_Intersection(ST_Intersection(l.geom, z.geom),
                                                 (SELECT geom FROM analysis.study_area))))).geom AS geom
    FROM lines l JOIN analysis.stream_zone z ON ST_Intersects(l.geom, z.geom)
)
SELECT row_number() OVER () AS line_id, fid AS stream_fid, name,
       geom::geometry(LineString, :crs) AS geom
FROM dumped
WHERE ST_GeometryType(geom) = 'ST_LineString' AND ST_Length(geom) > 5;
CREATE INDEX ON analysis.stream_lines USING gist (geom);

-- 2. Width measurements. Shore points every 2 m are enough to find the nearest bank
-- (a real table, so the distance join can use a spatial index).
DROP TABLE IF EXISTS analysis.shore_points_2m CASCADE;
CREATE TABLE analysis.shore_points_2m AS
SELECT ST_LineInterpolatePoint(s.geom, (j + 0.5) / k.n)::geometry(Point, :crs) AS pt
FROM analysis.shoreline s
CROSS JOIN LATERAL (SELECT greatest(1, round(ST_Length(s.geom) / 2))::int AS n) k
CROSS JOIN LATERAL generate_series(0, k.n - 1) j;
CREATE INDEX ON analysis.shore_points_2m USING gist (pt);

DROP TABLE IF EXISTS analysis.stream_width CASCADE;
CREATE TABLE analysis.stream_width AS
WITH probes AS (
    SELECT l.line_id, j,
           ST_LineInterpolatePoint(l.geom, (j + 0.5) / k.n) AS pt,
           ST_LineInterpolatePoint(l.geom, greatest(0, (j + 0.5) / k.n - 1 / ST_Length(l.geom))) AS a,
           ST_LineInterpolatePoint(l.geom, least(1, (j + 0.5) / k.n + 1 / ST_Length(l.geom))) AS b,
           k.n
    FROM analysis.stream_lines l
    CROSS JOIN LATERAL (SELECT greatest(1, round(ST_Length(l.geom) / :narrow_measure_step_m))::int AS n) k
    CROSS JOIN LATERAL generate_series(0, k.n - 1) j
),
sides AS (
    SELECT p.line_id, p.j,
           min(ST_Distance(p.pt, sp.pt)) FILTER (WHERE c > 0) AS left_m,
           min(ST_Distance(p.pt, sp.pt)) FILTER (WHERE c < 0) AS right_m
    FROM probes p
    JOIN analysis.shore_points_2m sp ON ST_DWithin(sp.pt, p.pt, :narrow_width_m * 1.5)
    CROSS JOIN LATERAL (SELECT
        (ST_X(p.b) - ST_X(p.a)) * (ST_Y(sp.pt) - ST_Y(p.pt))
      - (ST_Y(p.b) - ST_Y(p.a)) * (ST_X(sp.pt) - ST_X(p.pt)) AS c) x
    GROUP BY 1, 2
)
SELECT p.line_id, p.j, p.n, p.pt,
       -- a side with no shore inside the search radius counts as wide
       coalesce(s.left_m + s.right_m, 1e6) AS width_m
FROM probes p LEFT JOIN sides s USING (line_id, j);

-- 3. Smooth: rolling median, then absorb short runs.
CREATE INDEX ON analysis.stream_width (line_id, j);
ALTER TABLE analysis.stream_width ADD COLUMN width_smooth_m double precision,
                                  ADD COLUMN narrow boolean;
UPDATE analysis.stream_width w
SET width_smooth_m = (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY o.width_m)
    FROM analysis.stream_width o
    WHERE o.line_id = w.line_id
      AND abs(o.j - w.j) * :narrow_measure_step_m <= :narrow_smoothing_m / 2.0
);
UPDATE analysis.stream_width SET narrow = width_smooth_m < :narrow_width_m;

WITH runs AS (
    SELECT line_id, j, narrow,
           j - row_number() OVER (PARTITION BY line_id, narrow ORDER BY j) AS grp
    FROM analysis.stream_width
),
run_spans AS (
    SELECT line_id, narrow, grp, min(j) AS j0, max(j) AS j1,
           (max(j) - min(j) + 1) * :narrow_measure_step_m AS len_m
    FROM runs GROUP BY 1, 2, 3
),
ordered AS (
    SELECT *, lag(narrow) OVER w AS prev_narrow, lead(narrow) OVER w AS next_narrow,
           count(*) OVER (PARTITION BY line_id) AS runs_on_line
    FROM run_spans
    WINDOW w AS (PARTITION BY line_id ORDER BY j0)
)
UPDATE analysis.stream_width w
SET narrow = coalesce(o.prev_narrow, o.next_narrow)
FROM ordered o
WHERE o.line_id = w.line_id AND w.j BETWEEN o.j0 AND o.j1
  AND o.len_m < :narrow_min_run_m AND o.runs_on_line > 1;
CREATE INDEX ON analysis.stream_width USING gist (pt);

-- 4. Centerline steps, each with the class of the nearest measurement on its line.
DROP TABLE IF EXISTS analysis.stream_steps CASCADE;
CREATE TABLE analysis.stream_steps AS
SELECT l.line_id, i, k.n,
       ST_LineInterpolatePoint(l.geom, (i + 0.5) / k.n) AS pt,
       ST_LineInterpolatePoint(l.geom, i::float / k.n) AS p0,
       ST_LineInterpolatePoint(l.geom, (i + 1)::float / k.n) AS p1,
       w.narrow
FROM analysis.stream_lines l
CROSS JOIN LATERAL (SELECT greatest(1, round(ST_Length(l.geom) / :sample_step_m))::int AS n,
                           -- the line's measurement count, as computed for stream_width
                           greatest(1, round(ST_Length(l.geom) / :narrow_measure_step_m))::int AS nw) k
CROSS JOIN LATERAL generate_series(0, k.n - 1) i
-- The measurement index comes from the step alone, so the (line_id, j) index applies.
JOIN analysis.stream_width w
  ON w.line_id = l.line_id AND w.j = least(k.nw - 1, floor((i + 0.5) / k.n * k.nw)::int);
CREATE INDEX ON analysis.stream_steps USING gist (pt);
