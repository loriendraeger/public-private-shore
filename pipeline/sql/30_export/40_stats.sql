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

-- water_kind: 'wide' (lakes, wide rivers), 'narrow' (narrower than :narrow_width_m), or
-- 'pond' (standalone water the county and DNR don't name; the scorecard decides
-- whether ponds count).
-- Narrow water counts once: stream centerlines stand in for both banks; narrow banks
-- with no centerline (rare) count at half weight so the two banks add up to one.
DROP VIEW IF EXISTS export.stats_shore;
CREATE VIEW export.stats_shore AS
WITH pieces AS (
    SELECT s.muni_id, s.waterbody,
           CASE WHEN sl.water_class = 'pond' THEN 'pond'
                WHEN s.narrow THEN 'narrow' ELSE 'wide' END AS water_kind,
           s.category, CASE WHEN s.narrow THEN 0.5 ELSE 1 END * s.length_m AS length_m
    FROM analysis.shore_segments s
    JOIN analysis.shoreline sl USING (shore_id)
    WHERE NOT s.replaced
    UNION ALL
    SELECT muni_id, waterbody, CASE WHEN water_class = 'pond' THEN 'pond' ELSE 'narrow' END,
           category, length_m
    FROM analysis.stream_segments
)
SELECT muni_id, waterbody, water_kind, category,
       round(sum(length_m)::numeric, 1)::float AS length_m
FROM pieces
GROUP BY 1, 2, 3, 4;
