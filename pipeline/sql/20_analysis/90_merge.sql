-- Shore runs (milestone 5, decision 2026-10-18): what the map and the stats show.
-- Parcel-level segments (analysis.shore_segments) stay as the audit layer; here
-- adjacent ones that say the same thing become one run.
--
-- Banks (not replaced by a centerline): consecutive segments on the same shoreline merge
-- when they share category, municipality, narrow (narrow banks count half in stats),
-- owner class and label, and access source, kind and name (so runs split where the
-- park changes; unnamed paths all read "Public path" and merge). Labels are kept for private shore
-- too, so "Condo / HOA" and "Church" stay visible on the map. On a
-- closed ring (a whole lake or pond) the run touching the start and the run touching
-- the end merge if they match.
--
-- Centerlines (analysis.stream_segments, 80_streams.sql) are already runs of the same
-- result; they're copied as they are, with ids offset by 10,000,000.
--
-- Invariant, checked at the end: length per municipality x category x water kind is the
-- same before and after.

DROP TABLE IF EXISTS analysis.shore_runs CASCADE;
CREATE TABLE analysis.shore_runs AS
WITH banks AS MATERIALIZED (
    SELECT s.*, sl.water_class,
           concat_ws('|', s.category, s.muni_id, s.narrow, s.owner_class, s.owner_label,
                     s.access_source, s.access_kind, s.access_name) AS run_key
    FROM analysis.shore_segments s
    JOIN analysis.shoreline sl USING (shore_id)
    WHERE NOT s.replaced
),
-- segment_id follows position along each shoreline (30_shore_segments.sql), so
-- consecutive ids on one shore_id are neighbors: gaps-and-islands on it.
grouped AS (
    SELECT *, segment_id - row_number() OVER (PARTITION BY shore_id, run_key ORDER BY segment_id) AS grp
    FROM banks
),
spans AS (
    SELECT shore_id, run_key, grp, min(segment_id) AS first_id, max(segment_id) AS last_id
    FROM grouped GROUP BY 1, 2, 3
),
ends AS (
    SELECT shore_id, min(segment_id) AS first_id, max(segment_id) AS last_id
    FROM banks GROUP BY 1
),
-- Ring wrap-around: the run ending at the last segment joins the run starting at the
-- first, when they're different runs with the same key and really meet (the last
-- segment ends where the first starts; not so when the ring's ends were replaced by a
-- centerline).
wrap AS (
    SELECT t.shore_id, t.run_key, t.grp AS tail_grp, h.grp AS head_grp
    FROM spans t
    JOIN spans h ON h.shore_id = t.shore_id AND h.run_key = t.run_key AND h.grp <> t.grp
    JOIN ends e ON e.shore_id = t.shore_id
    JOIN banks lb ON lb.segment_id = e.last_id
    JOIN banks fb ON fb.segment_id = e.first_id
    WHERE t.last_id = e.last_id AND h.first_id = e.first_id
      AND ST_DWithin(ST_EndPoint(lb.geom), ST_StartPoint(fb.geom), 0.5)
),
final AS (
    SELECT g.*, coalesce(w.head_grp, g.grp) AS run_grp,
           -- order within the run: wrapped tail pieces come before the head
           CASE WHEN w.head_grp IS NOT NULL THEN 0 ELSE 1 END AS part
    FROM grouped g
    LEFT JOIN wrap w ON w.shore_id = g.shore_id AND w.run_key = g.run_key AND w.tail_grp = g.grp
)
SELECT
    min(segment_id) AS run_id,
    'bank'::text AS kind,
    shore_id,
    NULL::bigint AS line_id,
    -- every piece of a run shares these (in the key, or per shoreline)
    min(waterbody) AS waterbody, min(wbic) AS wbic, min(water_class) AS water_class,
    bool_and(narrow) AS narrow,
    min(muni_id) AS muni_id, min(muni_name) AS muni_name, min(muni_type) AS muni_type,
    min(category) AS category, min(owner_class) AS owner_class, min(owner_label) AS owner_label,
    NULL::text AS other_bank_label,
    min(access) AS access, min(access_source) AS access_source,
    min(access_kind) AS access_kind, min(access_name) AS access_name,
    min(access_label) AS access_label, min(access_reason) AS access_reason,
    array_agg(segment_id ORDER BY part, segment_id) AS segment_ids,
    ST_LineMerge(ST_Collect(geom ORDER BY part, segment_id)) AS geom
FROM final
GROUP BY shore_id, run_key, run_grp
UNION ALL
SELECT
    10000000 + stream_segment_id, 'stream', NULL, line_id,
    waterbody, wbic, water_class, true,
    muni_id, muni_name, muni_type, category, owner_class, owner_label,
    other_bank_label, access, access_source, access_kind, access_name, access_label,
    access_reason,
    bank_segment_ids, geom
FROM analysis.stream_segments;

ALTER TABLE analysis.shore_runs ADD PRIMARY KEY (run_id);
ALTER TABLE analysis.shore_runs ADD COLUMN length_m double precision
    GENERATED ALWAYS AS (ST_Length(geom)) STORED;
CREATE INDEX ON analysis.shore_runs USING gist (geom);

-- Invariant: merging moves no length between municipalities, categories or water kinds.
DO $$
DECLARE bad integer;
BEGIN
    WITH before AS (
        SELECT 'bank' AS kind, muni_id, category, narrow, sum(length_m) AS m
        FROM analysis.shore_segments WHERE NOT replaced GROUP BY 2, 3, 4
        UNION ALL
        SELECT 'stream', muni_id, category, true, sum(length_m)
        FROM analysis.stream_segments GROUP BY 2, 3
    ),
    after AS (
        SELECT kind, muni_id, category, narrow, sum(length_m) AS m
        FROM analysis.shore_runs GROUP BY 1, 2, 3, 4
    )
    SELECT count(*) INTO bad
    FROM before b FULL JOIN after a USING (kind, muni_id, category, narrow)
    WHERE abs(coalesce(b.m, 0) - coalesce(a.m, 0)) > 0.5;
    IF bad > 0 THEN
        RAISE EXCEPTION 'shore_runs: % kind x municipality x category groups changed length in the merge', bad;
    END IF;
END $$;
