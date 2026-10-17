-- Tables behind site/public/data/stats.json (written by `shore stats`). No geometry, so
-- they aren't tile layers. Tidy: one row per municipality x waterbody x category; the
-- site sums them however the user asks. Lengths in meters (the site converts units).

DROP VIEW IF EXISTS export.stats_municipalities;
CREATE VIEW export.stats_municipalities AS
SELECT
    m.muni_id,
    m.name,
    m.muni_type,
    p.pop_estimate AS population,
    p.pop_census_2020,
    -- [west, south, east, north] of the municipality's shore (EPSG:4326), for zooming
    -- the map to it; NULL when it has none.
    (SELECT ARRAY[ST_XMin(e), ST_YMin(e), ST_XMax(e), ST_YMax(e)]
     FROM (SELECT ST_Extent(ST_Transform(s.geom, 4326)) AS e
           FROM analysis.shore_segments s WHERE s.muni_id = m.muni_id) x
     WHERE e IS NOT NULL) AS shore_bbox
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
