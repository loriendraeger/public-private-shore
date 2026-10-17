-- Study area = union of the municipalities listed in pipeline.toml [study_area].
-- Fail loudly on a name that doesn't match, so a typo can't silently shrink the area.
DROP TABLE IF EXISTS analysis.study_area_munis CASCADE;
CREATE TABLE analysis.study_area_munis AS
SELECT m.muni_id, m.name
FROM staging.municipalities m
WHERE m.name = ANY (string_to_array(:'municipalities', ','));

-- psql doesn't interpolate :vars inside DO $$...$$; pass the list as a session setting.
SELECT set_config('shore.municipalities', :'municipalities', false) \gset

DO $$
DECLARE missing text;
BEGIN
    SELECT string_agg(n, ', ') INTO missing
    FROM unnest(string_to_array(current_setting('shore.municipalities'), ',')) n
    WHERE n NOT IN (SELECT name FROM analysis.study_area_munis);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'pipeline.toml [study_area] names not in staging.municipalities: %', missing;
    END IF;
END $$;

DROP TABLE IF EXISTS analysis.study_area CASCADE;
CREATE TABLE analysis.study_area AS
SELECT ST_Multi(ST_Union(m.geom))::geometry(MultiPolygon, :crs) AS geom
FROM staging.municipalities m
JOIN analysis.study_area_munis USING (muni_id);
CREATE INDEX ON analysis.study_area USING gist (geom);
