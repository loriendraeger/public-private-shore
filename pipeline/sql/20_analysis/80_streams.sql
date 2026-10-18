-- Narrow streams: collapse the two banks onto the stream's centerline (decision
-- 2026-10-17). Where the water is narrower than :narrow_width_m (25_narrow_water.sql),
-- the shore counts ONCE, along the centerline, and has public access if EITHER bank
-- does. Centerlines come from the Dane County Rivers and Streams lines, which run
-- through the county's own water polygons.
--
-- 1. 25_narrow_water.sql made analysis.stream_lines and analysis.stream_steps (every
--    :sample_step_m, with a smoothed narrow flag).
-- 2. Each narrow step finds the nearest narrow bank segment on its left and on its right
--    (within :stream_bank_distance_m; side = sign of the cross product of the line's
--    direction and the vector to the bank).
-- 3. Each step takes the better bank by :stream_category_priority (access first) and
--    inherits its category, owner label, access (with its reason) and municipality. Steps with no bank on
--    either side (e.g. the banks lie outside the study area) are dropped.
-- 4. Short runs (under :stream_min_run_m) of steps with the same result take the result
--    of the run before them (or after, at the start of a line): the better bank changes
--    whenever either bank changes owner, which left hundreds of pieces under 5 m.
-- 5. analysis.stream_segments: consecutive steps with the same result, as one segment.
--    The other bank isn't part of the result: its labels are listed.
-- 6. Bank segments a step matched are marked `replaced` and leave the map and stats.
--    Narrow banks no step matched (no centerline nearby) stay, at half weight in stats.

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
    WHERE st.narrow
)
SELECT DISTINCT ON (line_id, i, side) line_id, i, side, segment_id, dist
FROM cand
WHERE side <> 0
ORDER BY line_id, i, side, dist;

-- Per step: the better bank wins; the other bank is kept as a label for the map.
-- Real tables with indexes, not chained CTEs: the planner can't index a CTE, and a
-- self-join of ~150k steps once chose a plan that wrote 40 GB of temp files.
DROP TABLE IF EXISTS analysis.stream_step_results CASCADE;
CREATE TABLE analysis.stream_step_results AS
WITH ranked AS MATERIALIZED (
    SELECT m.line_id, m.i, s.segment_id, s.waterbody, s.wbic, s.muni_id, s.muni_name,
           s.muni_type, s.category, s.owner_class, s.owner_label, s.access, s.access_source,
           s.access_kind, s.access_name, s.access_label, s.access_reason, sl.water_class,
           row_number() OVER (
               PARTITION BY m.line_id, m.i
               ORDER BY array_position(string_to_array(:'stream_category_priority', ','), s.category),
                        m.dist
           ) AS rk
    FROM analysis.stream_bank_matches m
    JOIN analysis.shore_segments s USING (segment_id)
    JOIN analysis.shoreline sl ON sl.shore_id = s.shore_id
)
SELECT w.line_id, w.i, st.n, w.segment_id, w.waterbody, w.wbic, w.muni_id, w.muni_name,
       w.muni_type, w.category, w.owner_class, w.owner_label, w.access, w.access_source,
       w.access_kind, w.access_name, w.access_label, w.access_reason, w.water_class,
       concat_ws('|', w.category, w.owner_label, w.muni_id, w.access_source, w.access_kind,
                 w.access_name, w.water_class) AS run_key,
       o.owner_label AS other_bank_label, o.category AS other_bank_category
FROM ranked w
JOIN analysis.stream_steps st USING (line_id, i)
LEFT JOIN ranked o ON o.line_id = w.line_id AND o.i = w.i AND o.rk = 2
WHERE w.rk = 1;
CREATE UNIQUE INDEX ON analysis.stream_step_results (line_id, i);
ANALYZE analysis.stream_step_results;

-- Short runs: which step each step takes its result from. Itself, or for a run shorter
-- than :stream_min_run_m the last step of the run before (else the first step of the
-- run after). One pass, like the banks.
DROP TABLE IF EXISTS analysis.stream_step_source CASCADE;
CREATE TABLE analysis.stream_step_source AS
WITH runs AS (
    SELECT line_id, i, run_key, i - row_number() OVER (PARTITION BY line_id, run_key ORDER BY i) AS grp
    FROM analysis.stream_step_results
),
spans AS (
    SELECT line_id, run_key, grp, min(i) AS i0, max(i) AS i1, count(*) AS n_steps
    FROM runs GROUP BY 1, 2, 3
),
neighbors AS (
    SELECT *, lag(i1) OVER w AS prev_i, lead(i0) OVER w AS next_i,
           count(*) OVER (PARTITION BY line_id) AS runs_on_line
    FROM spans
    WINDOW w AS (PARTITION BY line_id ORDER BY i0)
)
SELECT r.line_id, r.i,
       CASE WHEN nb.n_steps * :sample_step_m < :stream_min_run_m AND nb.runs_on_line > 1
            THEN coalesce(nb.prev_i, nb.next_i) ELSE r.i END AS from_i
FROM runs r JOIN neighbors nb USING (line_id, run_key, grp);
CREATE UNIQUE INDEX ON analysis.stream_step_source (line_id, i);

DROP TABLE IF EXISTS analysis.stream_segments CASCADE;
CREATE TABLE analysis.stream_segments AS
WITH keyed AS (
    SELECT f.line_id, own.i, own.n, f.segment_id, f.waterbody, f.wbic, f.muni_id, f.muni_name,
           f.muni_type, f.category, f.owner_class, f.owner_label, f.access, f.access_source,
           f.access_kind, f.access_name, f.access_label, f.access_reason, f.water_class,
           own.other_bank_label, own.other_bank_category,
           f.run_key
    FROM analysis.stream_step_source ss
    JOIN analysis.stream_step_results own ON own.line_id = ss.line_id AND own.i = ss.i
    JOIN analysis.stream_step_results f ON f.line_id = ss.line_id AND f.i = ss.from_i
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
           min(access_source) AS access_source, min(access_kind) AS access_kind,
           min(access_name) AS access_name, min(access_label) AS access_label,
           min(access_reason) AS access_reason,
           min(water_class) AS water_class,
           string_agg(DISTINCT other_bank_label, '; ') AS other_bank_label,
           string_agg(DISTINCT other_bank_category, '; ') AS other_bank_category,
           array_agg(DISTINCT segment_id) AS bank_segment_ids
    FROM runs GROUP BY line_id, run_key, grp
)
SELECT
    row_number() OVER (ORDER BY s.line_id, s.i0) AS stream_segment_id,
    s.line_id, s.waterbody, s.wbic, s.muni_id, s.muni_name, s.muni_type,
    s.category, s.owner_class, s.owner_label, s.access, s.access_source, s.access_kind,
    s.access_name, s.access_label, s.access_reason,
    s.water_class, s.other_bank_label, s.other_bank_category, s.bank_segment_ids,
    ST_LineSubstring(l.geom, s.i0::float / s.n, (s.i1 + 1)::float / s.n)::geometry(LineString, :crs) AS geom
FROM segs s JOIN analysis.stream_lines l USING (line_id);

ALTER TABLE analysis.stream_segments ADD PRIMARY KEY (stream_segment_id);
ALTER TABLE analysis.stream_segments ADD COLUMN length_m double precision
    GENERATED ALWAYS AS (ST_Length(geom)) STORED;
CREATE INDEX ON analysis.stream_segments USING gist (geom);

CREATE INDEX ON analysis.stream_bank_matches (segment_id);

-- Banks represented by a centerline leave the map and the stats.
ALTER TABLE analysis.shore_segments ADD COLUMN IF NOT EXISTS replaced boolean;
UPDATE analysis.shore_segments s
SET replaced = EXISTS (SELECT 1 FROM analysis.stream_bank_matches m WHERE m.segment_id = s.segment_id);
