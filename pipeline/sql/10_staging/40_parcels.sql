-- Parcels (SCO V12, already EPSG:3071). Keep only what classification and auditing need.
-- Raw owner names stay in the database for auditing and are never exported.
DROP TABLE IF EXISTS staging.parcels CASCADE;
CREATE TABLE staging.parcels AS
SELECT
    fid AS parcel_id,
    parcelid AS source_parcel_id,
    upper(trim(ownernme1)) AS owner1,
    nullif(upper(trim(ownernme2)), '') AS owner2,
    placename,          -- municipality the parcel lies in, e.g. 'VILLAGE OF MAPLE BLUFF'
    nullif(auxclass, '') AS auxclass,   -- X1-X4 exemption codes: a secondary signal only
    nullif(propclass, '') AS propclass,
    ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))::geometry(MultiPolygon, :crs) AS geom
FROM raw.parcels;

ALTER TABLE staging.parcels ADD PRIMARY KEY (parcel_id);
CREATE INDEX ON staging.parcels USING gist (geom);
