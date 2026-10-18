-- Split the shoreline into segments wherever the adjacent owner (or its municipality)
-- changes, or the water changes between narrow and wide (25_narrow_water.sql).
--
-- Method: sampling. Cut each shoreline into steps of about :sample_step_m, assign each
-- step's midpoint to the nearest parcel within :snap_tolerance_m (none = a gap), then
-- collapse consecutive steps with the same (owner, municipality) into one segment.
-- Segment geometry is the exact ST_LineSubstring between the change points.
--
-- Merging on the owner name rather than the parcel means large holdings split along
-- PLSS lines (e.g. the UW Arboretum) become one segment. Merging also keys on the
-- municipality, so one owner's shore across a municipal line stays two segments.

-- Steps: (shore_id, i) covers fractions [i/n, (i+1)/n] of the line.
DROP TABLE IF EXISTS analysis.shore_steps CASCADE;
CREATE TABLE analysis.shore_steps AS
SELECT s.shore_id, i, n,
       ST_LineInterpolatePoint(s.geom, (i + 0.5) / n) AS pt
FROM analysis.shoreline s
CROSS JOIN LATERAL (SELECT greatest(1, round(ST_Length(s.geom) / :sample_step_m))::int AS n) k
CROSS JOIN LATERAL generate_series(0, k.n - 1) i;

-- Parcels near the shoreline, with the municipality each lies in. Municipality comes
-- from the land side (decision 2026-10-17): municipal polygons include lake water, so
-- the shoreline itself would say "City of Madison" for Maple Bluff's shore.
DROP TABLE IF EXISTS analysis.shore_parcels CASCADE;
CREATE TABLE analysis.shore_parcels AS
SELECT p.parcel_id, p.owner1, p.placename, m.muni_id, p.geom
FROM staging.parcels p
LEFT JOIN LATERAL (
    SELECT muni_id FROM staging.municipalities m
    WHERE ST_Intersects(m.geom, ST_PointOnSurface(p.geom))
    LIMIT 1
) m ON true
WHERE EXISTS (
    SELECT 1 FROM analysis.shoreline s WHERE ST_DWithin(p.geom, s.geom, :snap_tolerance_m)
);
CREATE INDEX ON analysis.shore_parcels USING gist (geom);

ALTER TABLE analysis.shore_steps ADD COLUMN parcel_id integer;
UPDATE analysis.shore_steps st
SET parcel_id = (
    -- Distance to the parcel polygon (0 when the shoreline runs inside the parcel,
    -- as it does where parcels reach into marsh), not to the parcel's edge.
    SELECT p.parcel_id FROM analysis.shore_parcels p
    WHERE ST_DWithin(p.geom, st.pt, :snap_tolerance_m)
    ORDER BY ST_Distance(p.geom, st.pt), p.parcel_id
    LIMIT 1
);

-- Narrow (25_narrow_water.sql): the class of the nearest centerline step within
-- :stream_bank_distance_m, so banks and centerline always agree. Shore with no
-- centerline nearby falls back to the opening test: no wide water near the step. Its
-- margin (0.225 x width, i.e. 0.45 x the opening radius) absorbs the rounding the
-- opening applies to convex corners, so lake corners aren't mistaken for channels.
ALTER TABLE analysis.shore_steps ADD COLUMN narrow boolean;
UPDATE analysis.shore_steps st
SET narrow = coalesce(
    (SELECT c.narrow FROM analysis.stream_steps c
     WHERE ST_DWithin(c.pt, st.pt, :stream_bank_distance_m)
     ORDER BY c.pt <-> st.pt LIMIT 1),
    NOT EXISTS (
        SELECT 1 FROM analysis.wide_water w
        WHERE ST_DWithin(w.geom, st.pt, greatest(1.5, :narrow_width_m * 0.225))
    )
);

-- Only flowing water is "narrow" (decision 2026-10-18): shore of Lake-type polygons
-- (lakes and ponds, including their narrow arms and inlets) keeps both banks. County
-- hydtype River, or none (the main Yahara polygon), counts as flowing.
UPDATE analysis.shore_steps st
SET narrow = false
WHERE st.narrow
  AND (SELECT p.hydtype FROM analysis.water_type_pieces p
       WHERE ST_DWithin(p.geom, st.pt, 2)
       ORDER BY p.geom <-> st.pt LIMIT 1) = 'Lake';

-- Absorb short runs (:segment_min_run_m), one pass each. Ring wrap-around is ignored.
-- 1. Narrow/wide: a short run flips to its neighbors' value.
WITH runs AS (
    SELECT shore_id, i, narrow,
           i - row_number() OVER (PARTITION BY shore_id, narrow ORDER BY i) AS grp
    FROM analysis.shore_steps
),
spans AS (
    SELECT shore_id, narrow, grp, min(i) AS i0, max(i) AS i1, count(*) AS n
    FROM runs GROUP BY 1, 2, 3
),
o AS (
    SELECT *, count(*) OVER (PARTITION BY shore_id) AS runs_on_line FROM spans
)
UPDATE analysis.shore_steps st
SET narrow = NOT o.narrow
FROM o
WHERE o.shore_id = st.shore_id AND st.i BETWEEN o.i0 AND o.i1
  AND o.n * :sample_step_m < :segment_min_run_m AND o.runs_on_line > 1;

-- 2. Owners: a short owned run takes the parcel of the owned run before it (or after
--    it, at the start of a line). Gaps are never absorbed and never absorb: they may
--    be street ends, which can be narrower than the threshold.
WITH keyed AS (
    SELECT st.shore_id, st.i, st.parcel_id,
           coalesce(p.owner1, '') || '|' || coalesce(p.muni_id::text, '') AS k
    FROM analysis.shore_steps st
    LEFT JOIN analysis.shore_parcels p USING (parcel_id)
),
runs AS (
    SELECT *, i - row_number() OVER (PARTITION BY shore_id, k ORDER BY i) AS grp
    FROM keyed
),
spans AS (
    SELECT shore_id, k, grp, min(i) AS i0, max(i) AS i1, count(*) AS n,
           bool_and(parcel_id IS NULL) AS is_gap, min(parcel_id) AS pid
    FROM runs GROUP BY 1, 2, 3
),
o AS (
    SELECT *, lag(pid) OVER w AS prev_pid, lag(is_gap) OVER w AS prev_gap,
              lead(pid) OVER w AS next_pid, lead(is_gap) OVER w AS next_gap
    FROM spans
    WINDOW w AS (PARTITION BY shore_id ORDER BY i0)
),
fix AS (
    SELECT shore_id, i0, i1,
           CASE WHEN prev_gap IS FALSE THEN prev_pid
                WHEN next_gap IS FALSE THEN next_pid END AS new_pid
    FROM o
    WHERE NOT is_gap AND n * :sample_step_m < :segment_min_run_m
)
UPDATE analysis.shore_steps st
SET parcel_id = f.new_pid
FROM fix f
WHERE f.shore_id = st.shore_id AND st.i BETWEEN f.i0 AND f.i1 AND f.new_pid IS NOT NULL;

-- Gaps-and-islands: consecutive steps with the same key form one run.
DROP TABLE IF EXISTS analysis.shore_segments CASCADE;
CREATE TABLE analysis.shore_segments AS
WITH keyed AS (
    SELECT st.shore_id, st.i, st.n, st.parcel_id, p.owner1, p.muni_id, st.narrow,
           -- Gaps get a NULL owner; coalesce so consecutive gap steps share a key.
           coalesce(p.owner1, '') || '|' || coalesce(p.muni_id::text, '') || '|'
               || st.narrow::text AS run_key
    FROM analysis.shore_steps st
    LEFT JOIN analysis.shore_parcels p USING (parcel_id)
),
runs AS (
    SELECT *, i - row_number() OVER (PARTITION BY shore_id, run_key ORDER BY i) AS grp
    FROM keyed
),
segs AS (
    SELECT shore_id, run_key, grp,
           min(owner1) AS owner1, min(muni_id) AS muni_id, bool_and(narrow) AS narrow,
           array_agg(DISTINCT parcel_id) FILTER (WHERE parcel_id IS NOT NULL) AS parcel_ids,
           min(i) AS i0, max(i) AS i1, min(n) AS n
    FROM runs GROUP BY shore_id, run_key, grp
),
-- On a closed ring, the run touching the start and the run touching the end are the
-- same stretch of shore if they share a key. Merge them.
wrapped AS (
    SELECT s.*,
           (sh_closed AND n > 0 AND i1 = n - 1 AND EXISTS (
               SELECT 1 FROM segs f WHERE f.shore_id = s.shore_id AND f.i0 = 0
                 AND f.run_key = s.run_key AND f.grp <> s.grp)) AS is_tail
    FROM segs s
    CROSS JOIN LATERAL (SELECT ST_IsClosed(geom) AS sh_closed FROM analysis.shoreline WHERE shore_id = s.shore_id) c
),
pieces AS (
    SELECT w.*, ST_LineSubstring(sh.geom, w.i0::float / w.n, (w.i1 + 1)::float / w.n) AS geom
    FROM wrapped w JOIN analysis.shoreline sh USING (shore_id)
)
SELECT
    row_number() OVER (ORDER BY h.shore_id, h.i0) AS segment_id,
    h.shore_id, sh.waterbody, sh.wbic,
    h.owner1, h.muni_id, h.narrow,
    (SELECT array_agg(DISTINCT x ORDER BY x) FROM unnest(h.parcel_ids || coalesce(t.parcel_ids, '{}')) x) AS parcel_ids,
    CASE WHEN t.geom IS NULL THEN h.geom
         ELSE ST_LineMerge(ST_Collect(t.geom, h.geom)) END::geometry(LineString, :crs) AS geom
FROM pieces h
JOIN analysis.shoreline sh USING (shore_id)
LEFT JOIN pieces t ON t.is_tail AND t.shore_id = h.shore_id AND t.run_key = h.run_key AND h.i0 = 0
WHERE NOT h.is_tail;

ALTER TABLE analysis.shore_segments ADD PRIMARY KEY (segment_id);
ALTER TABLE analysis.shore_segments ADD COLUMN length_m double precision
    GENERATED ALWAYS AS (ST_Length(geom)) STORED;
CREATE INDEX ON analysis.shore_segments USING gist (geom);
