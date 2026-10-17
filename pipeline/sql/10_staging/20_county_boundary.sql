-- Dane County outline = union of the municipalities. They tile the county exactly
-- (one part, no holes, no overlaps), so no separate county-boundary source is needed.
-- This is the clip mask for everything else.
DROP TABLE IF EXISTS staging.county_boundary CASCADE;
CREATE TABLE staging.county_boundary AS
SELECT ST_Multi(ST_Union(geom))::geometry(MultiPolygon, :crs) AS geom
FROM staging.municipalities;

CREATE INDEX ON staging.county_boundary USING gist (geom);
