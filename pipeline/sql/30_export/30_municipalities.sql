-- Tile layers `municipalities` (outlines) and `municipality_labels` (one point each).
-- A separate label point avoids MapLibre placing a polygon label once per tile.
-- Note: municipal polygons include lake water (e.g. Lake Wingra is in the City of
-- Madison), so boundaries run across lakes.
CREATE OR REPLACE VIEW export.municipalities AS
SELECT
    muni_id,
    name,
    muni_type,
    ST_Transform(geom, 4326)::geometry(MultiPolygon, 4326) AS geom
FROM staging.municipalities;

CREATE OR REPLACE VIEW export.municipality_labels AS
SELECT
    muni_id,
    name,
    muni_type,
    ST_Transform(ST_PointOnSurface(geom), 4326)::geometry(Point, 4326) AS geom
FROM staging.municipalities;
