-- Narrow streams: collapse the two banks onto the stream's centerline (decision
-- 2026-10-17). Where the water is narrower than :narrow_width_m (25_narrow_water.sql),
-- the shore counts ONCE, along the centerline, and has public access if EITHER bank
-- does. Centerlines come from the Dane County Rivers and Streams lines, which run
-- through the county's own water polygons.
--
-- 1. analysis.stream_lines: county stream lines in (or within half the narrow width of)
--    in-scope water, in the study area. Not clipped to the water exactly: on 6 m creeks
--    the separately digitized centerline often strays a few meters outside the polygon.
-- 2. analysis.stream_steps: the lines sampled every :sample_step_m, kept where the water
--    is narrow. Each step finds the nearest NARROW bank segment on its left and on its
--    right (within :stream_bank_distance_m; side = sign of the cross product of the
--    line's direction and the vector to the bank).
-- 3. Each step takes the better bank by :stream_category_priority (access first) and
--    inherits its category, owner label, access and municipality. Steps with no bank on
--    either side (e.g. the banks lie outside the study area) are dropped.
-- 4. analysis.stream_segments: consecutive steps with the same result, as one segment.
-- 5. Bank segments a step matched are marked `replaced` and leave the map and stats.
--    Narrow banks no step matched (no centerline nearby) stay, at half weight in stats.

DROP TABLE IF EXISTS analysis.stream_lines CASCADE;
CREATE TABLE analysis.stream_lines AS
WITH lines AS (
    SELECT cs.fid, cs.name, ST_Transform(cs.geom, :crs) AS geom
    FROM raw.county_streams cs
    -- Not culverted / underground. coalesce: most lines have no dxflayer, and a NULL
    -- would make the whole condition NULL (= dropped).
    WHERE coalesce(cs.dxflayer, '') NOT ILIKE '%hidden%'
      AND coalesce(cs.hydtype, '') NOT ILIKE 'hidden%'
),
zone AS MATERIALIZED (
    SELECT ST_Intersection(ST_Buffer(wp.geom, :narrow_width_m / 2.0, 'quad_segs=4'),
                           (SELECT geom FROM analysis.study_area)) AS geom
    FROM analysis.water_parts wp
),
clipped AS (
    SELECT l.fid, l.name,
           (ST_Dump(ST_LineMerge(ST_Intersection(l.geom, z.geom)))).geom AS geom
    FROM lines l JOIN zone z ON ST_Intersects(l.geom, z.geom)
)
SELECT row_number() OVER () AS line_id, fid AS stream_fid, name,
       geom::geometry(LineString, :crs) AS geom
FROM clipped
WHERE ST_GeometryType(geom) = 'ST_LineString' AND ST_Length(geom) > 5;
CREATE INDEX ON analysis.stream_lines USING gist (geom);

DROP TABLE IF EXISTS analysis.stream_steps CASCADE;
CREATE TABLE analysis.stream_steps AS
SELECT l.line_id, i, n,
       ST_LineInterpolatePoint(l.geom, (i + 0.5) / n) AS pt,
       ST_LineInterpolatePoint(l.geom, i::float / n) AS p0,
       ST_LineInterpolatePoint(l.geom, (i + 1)::float / n) AS p1
FROM analysis.stream_lines l
CROSS JOIN LATERAL (SELECT greatest(1, round(ST_Length(l.geom) / :sample_step_m))::int AS n) k
CROSS JOIN LATERAL generate_series(0, k.n - 1) i;
DELETE FROM analysis.stream_steps st
WHERE EXISTS (SELECT 1 FROM analysis.wide_water w
              WHERE ST_DWithin(w.geom, st.pt, greatest(1.5, :narrow_width_m * 0.225)));
CREATE INDEX ON analysis.stream_steps USING gist (pt);

-- Nearest narrow bank on each side of every step.
DROP TABLE IF EXISTS analysis.stream_bank_matches CASCADE;
CREATE TABLE analysis.stream_bank_matches AS
WITH cand AS (
    SELECT st.line_id, st.i, s.segment_id,
           ST_Distance(s.geom, st.pt) AS dist,
           sign((ST_X(st.p1) - ST_X(st.p0)) * (ST_Y(c.cp) - ST_Y(st.pt))
              - (ST_Y(st.p1) - ST_Y(st.p0)) * (ST_X(c.cp) - ST_X(st.pt))) AS side
    FROM analysis.stream_steps st
    JOIN analysis.shore_segments s
      ON s.narrow AND ST_DWithin(s.geom, st.pt, :stream_bank_distance_m)
    CROSS JOIN LATERAL (SELECT ST_ClosestPoint(s.geom, st.pt) AS cp) c
)
SELECT DISTINCT ON (line_id, i, side) line_id, i, side, segment_id, dist
FROM cand
WHERE side <> 0
ORDER BY line_id, i, side, dist;

-- Per step: the better bank wins; the other bank is kept as a label for the map.
DROP TABLE IF EXISTS analysis.stream_segments CASCADE;
CREATE TABLE analysis.stream_segments AS
WITH ranked AS (
    SELECT m.line_id, m.i, s.*,
           row_number() OVER (
               PARTITION BY m.line_id, m.i
               ORDER BY array_position(string_to_array(:'stream_category_priority', ','), s.category),
                        m.dist
           ) AS rk
    FROM analysis.stream_bank_matches m
    JOIN analysis.shore_segments s USING (segment_id)
),
per_step AS (
    SELECT w.line_id, w.i, st.n, w.segment_id, w.waterbody, w.wbic, w.muni_id, w.muni_name,
           w.muni_type, w.category, w.owner_class, w.owner_label, w.access, w.access_source,
           w.access_note, o.owner_label AS other_bank_label, o.category AS other_bank_category
    FROM ranked w
    JOIN analysis.stream_steps st USING (line_id, i)
    LEFT JOIN ranked o ON o.line_id = w.line_id AND o.i = w.i AND o.rk = 2
    WHERE w.rk = 1
),
keyed AS (
    SELECT *,
           concat_ws('|', category, owner_label, muni_id, access_source, access_note,
                     other_bank_label, other_bank_category) AS run_key
    FROM per_step
),
runs AS (
    SELECT *, i - row_number() OVER (PARTITION BY line_id, run_key ORDER BY i) AS grp
    FROM keyed
),
segs AS (
    SELECT line_id, run_key, grp, min(i) AS i0, max(i) AS i1, min(n) AS n,
           -- every step in a run shares these (they're in the key); min() just picks one
           min(waterbody) AS waterbody, min(wbic) AS wbic, min(muni_id) AS muni_id,
           min(muni_name) AS muni_name, min(muni_type) AS muni_type,
           min(category) AS category, min(owner_class) AS owner_class,
           min(owner_label) AS owner_label, min(access) AS access,
           min(access_source) AS access_source, min(access_note) AS access_note,
           min(other_bank_label) AS other_bank_label,
           min(other_bank_category) AS other_bank_category,
           array_agg(DISTINCT segment_id) AS bank_segment_ids
    FROM runs GROUP BY line_id, run_key, grp
)
SELECT
    row_number() OVER (ORDER BY s.line_id, s.i0) AS stream_segment_id,
    s.line_id, s.waterbody, s.wbic, s.muni_id, s.muni_name, s.muni_type,
    s.category, s.owner_class, s.owner_label, s.access, s.access_source, s.access_note,
    s.other_bank_label, s.other_bank_category, s.bank_segment_ids,
    ST_LineSubstring(l.geom, s.i0::float / s.n, (s.i1 + 1)::float / s.n)::geometry(LineString, :crs) AS geom
FROM segs s JOIN analysis.stream_lines l USING (line_id);

ALTER TABLE analysis.stream_segments ADD PRIMARY KEY (stream_segment_id);
ALTER TABLE analysis.stream_segments ADD COLUMN length_m double precision
    GENERATED ALWAYS AS (ST_Length(geom)) STORED;
CREATE INDEX ON analysis.stream_segments USING gist (geom);

-- Banks represented by a centerline leave the map and the stats.
ALTER TABLE analysis.shore_segments ADD COLUMN IF NOT EXISTS replaced boolean;
UPDATE analysis.shore_segments s
SET replaced = EXISTS (SELECT 1 FROM analysis.stream_bank_matches m WHERE m.segment_id = s.segment_id);
