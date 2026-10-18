-- OSM evidence for the access model, and roads for gap (ROW) classification.
-- Only multipolygons have leisure/natural/amenity columns in GDAL's default osmconf;
-- everything else is in the other_tags hstore, so read both.

DROP TABLE IF EXISTS staging.osm_access_features CASCADE;
CREATE TABLE staging.osm_access_features AS
WITH tagged AS (
    SELECT osm_id::text AS osm_id, 'area' AS kind, name, other_tags,
           leisure, "natural" AS natural_, amenity, man_made, geom
    FROM raw.osm_multipolygons
    UNION ALL
    SELECT osm_id, 'point', name, other_tags,
           other_tags->'leisure', other_tags->'natural', other_tags->'amenity', man_made, geom
    FROM raw.osm_points
    UNION ALL
    SELECT osm_id, 'line', name, other_tags,
           other_tags->'leisure', other_tags->'natural', other_tags->'amenity', man_made, geom
    FROM raw.osm_lines
)
SELECT
    row_number() OVER () AS feature_id,
    osm_id,
    kind,
    name,
    CASE
        WHEN leisure = 'slipway'                     THEN 'slipway'
        WHEN leisure = 'park'                        THEN 'park'
        WHEN leisure = 'nature_reserve'              THEN 'nature_reserve'
        WHEN natural_ = 'beach'                      THEN 'beach'
        WHEN leisure IN ('beach_resort', 'swimming_area') THEN 'swimming'
        WHEN leisure = 'marina'                      THEN 'marina'
        WHEN amenity = 'boat_rental'                 THEN 'boat_rental'
        WHEN man_made = 'pier'                       THEN 'pier'
        WHEN leisure = 'fishing'                     THEN 'fishing'
    END AS category,
    other_tags->'access' AS access,               -- e.g. private, yes, permissive (sparse)
    other_tags->'operator' AS operator,
    ST_Transform(geom, :crs) AS geom
FROM tagged
WHERE leisure IN ('slipway', 'park', 'nature_reserve', 'beach_resort', 'swimming_area', 'marina', 'fishing')
   OR natural_ = 'beach' OR amenity = 'boat_rental' OR man_made = 'pier';

CREATE INDEX ON staging.osm_access_features USING gist (geom);

-- Roads, for classifying unparceled shoreline as right-of-way.
DROP TABLE IF EXISTS staging.osm_roads CASCADE;
CREATE TABLE staging.osm_roads AS
SELECT
    osm_id,
    name,
    highway,
    -- Public streets vs. paths and private/service ways. Street ends count as access.
    highway IN ('motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'unclassified',
                'residential', 'living_street', 'motorway_link', 'trunk_link',
                'primary_link', 'secondary_link', 'tertiary_link') AS is_street,
    other_tags->'access' AS access,
    ST_Transform(geom, :crs)::geometry(LineString, :crs) AS geom
FROM raw.osm_lines
WHERE highway IS NOT NULL;

CREATE INDEX ON staging.osm_roads USING gist (geom);

-- Railways: barriers between land and shore (60_access.sql). Active and disused track
-- only: crossing it on foot is trespassing. Abandoned lines are often trails by now.
DROP TABLE IF EXISTS staging.osm_railways CASCADE;
CREATE TABLE staging.osm_railways AS
SELECT osm_id, name, railway,
       coalesce(other_tags->'bridge', 'no') NOT IN ('no', '') AS bridge,
       ST_Transform(geom, :crs)::geometry(LineString, :crs) AS geom
FROM raw.osm_lines
WHERE railway IN ('rail', 'disused');

CREATE INDEX ON staging.osm_railways USING gist (geom);
