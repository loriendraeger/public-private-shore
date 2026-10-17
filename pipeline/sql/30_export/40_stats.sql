-- Tables behind site/public/data/stats.json (written by `shore stats`). No geometry, so
-- they aren't tile layers. Tidy: one row per municipality x waterbody x category; the
-- site sums them however the user asks. Lengths in meters (the site converts units).

CREATE OR REPLACE VIEW export.stats_municipalities AS
SELECT
    m.muni_id,
    m.name,
    m.muni_type,
    p.pop_estimate AS population,
    p.pop_census_2020
FROM analysis.study_area_munis sa
JOIN staging.municipalities m USING (muni_id)
JOIN staging.population p USING (muni_id);

-- lake or river: the county hydro type of the waterbody's largest polygon.
CREATE OR REPLACE VIEW export.stats_shore AS
WITH kinds AS (
    SELECT DISTINCT ON (name, wbic) name, wbic,
           CASE WHEN hydtype = 'River' THEN 'river' ELSE 'lake' END AS water_kind
    FROM staging.water
    WHERE name IS NOT NULL
    ORDER BY name, wbic, area_m2 DESC
)
SELECT
    s.muni_id,
    s.waterbody,
    k.water_kind,
    s.category,
    round(sum(s.length_m)::numeric, 1)::float AS length_m
FROM analysis.shore_segments s
LEFT JOIN kinds k ON k.name = s.waterbody AND k.wbic IS NOT DISTINCT FROM s.wbic
GROUP BY 1, 2, 3, 4;
