-- Tile layer `parks`: OSM parks and nature reserves near the in-scope shoreline, for
-- context on the map. Other access evidence (slipways, beaches, ...) informs segment
-- access only and isn't exported as map features.
CREATE OR REPLACE VIEW export.parks AS
SELECT
    f.feature_id,
    f.name,
    f.category,
    ST_Transform(ST_MakeValid(f.geom), 4326) AS geom
FROM staging.osm_access_features f
WHERE f.kind = 'area'
  AND f.category IN ('park', 'nature_reserve')
  AND EXISTS (SELECT 1 FROM analysis.shoreline s WHERE ST_DWithin(f.geom, s.geom, 100));
