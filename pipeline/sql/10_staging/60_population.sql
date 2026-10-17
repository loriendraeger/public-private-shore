-- Population per municipality (the Dane County part of it), from the WI DOA final
-- estimates for 1/1/2026. These follow current boundaries, unlike Census 2020.
-- raw.population keeps the spreadsheet's generic columns (rows 1-3 are a title and
-- row 4 the header); see config/sources.toml [population].
DROP TABLE IF EXISTS staging.population CASCADE;
CREATE TABLE staging.population AS
WITH parsed AS (
    SELECT
        -- 'C Madison3' -> 'City of Madison' (trailing digits are footnote markers)
        CASE left(field2, 1) WHEN 'C' THEN 'City of ' WHEN 'V' THEN 'Village of '
                             WHEN 'T' THEN 'Town of ' END
            || regexp_replace(substr(field2, 3), '\d+$', '') AS name,
        field5::int AS pop_estimate,
        field6::int AS pop_census_2020
    FROM raw.population
    WHERE field4 = 'Dane' AND field1 ~ '^\d+$'
)
SELECT m.muni_id, p.name, p.pop_estimate, p.pop_census_2020
FROM parsed p
JOIN staging.municipalities m ON m.name = p.name;

ALTER TABLE staging.population ADD PRIMARY KEY (muni_id);

-- Every municipality must have a population.
DO $$
DECLARE missing text;
BEGIN
    SELECT string_agg(name, ', ') INTO missing
    FROM staging.municipalities m
    WHERE NOT EXISTS (SELECT 1 FROM staging.population p WHERE p.muni_id = m.muni_id);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'no population for: %', missing;
    END IF;
END $$;
