-- Extensions and schemas. Each SQL stage writes only to its own schema:
--   raw       as loaded by ogr2ogr (source CRS, untouched attributes)
--   staging   cleaned, valid, reprojected to :crs
--   analysis  shoreline, segments, classification
--   export    views shaped for tiles and stats
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;   -- OSM other_tags

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS analysis;
CREATE SCHEMA IF NOT EXISTS export;
