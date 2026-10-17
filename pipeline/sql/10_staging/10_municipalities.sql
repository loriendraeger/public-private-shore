-- Municipalities (cities, villages, towns) in the analysis CRS.
-- The county layer delivers WISCRS Dane in US feet (EPSG:7599); ST_Transform to :crs
-- (meters) so lengths and areas downstream are in meters.
DROP TABLE IF EXISTS staging.municipalities CASCADE;
CREATE TABLE staging.municipalities AS
SELECT
    fid AS muni_id,
    name,                                         -- display-ready, e.g. 'Village of Maple Bluff'
    CASE c_t_v WHEN 'C' THEN 'city' WHEN 'V' THEN 'village' WHEN 'T' THEN 'town' END AS muni_type,
    fipscode,
    -- A couple of source polygons self-intersect. ST_MakeValid can return a collection;
    -- keep only the polygonal part.
    ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Transform(geom, :crs)), 3))::geometry(MultiPolygon, :crs) AS geom
FROM raw.municipalities;

ALTER TABLE staging.municipalities ADD PRIMARY KEY (muni_id);
CREATE INDEX ON staging.municipalities USING gist (geom);
