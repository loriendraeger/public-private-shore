-- Narrow water: the parts of the in-scope water narrower than :narrow_width_m.
--
-- Method: morphological OPENING. Shrink the water by half the width (negative buffer),
-- then grow it back by the same amount. Channels narrower than the width vanish in the
-- shrink and don't come back; lakes and wide rivers return almost unchanged (only sharp
-- corners get rounded). Shore that ends up away from the opened water borders narrow
-- water. Width is local: one river can switch between narrow reaches and wide marshes.
--
-- analysis.water_parts  the unioned in-scope water (one row per connected piece)
-- analysis.wide_water   the opened water: everything at least :narrow_width_m wide

DROP TABLE IF EXISTS analysis.water_parts CASCADE;
CREATE TABLE analysis.water_parts AS
SELECT row_number() OVER () AS part_id, d.geom::geometry(Polygon, :crs) AS geom
FROM (
    SELECT ST_Union(w.geom) AS geom FROM staging.water w
    WHERE EXISTS (SELECT 1 FROM analysis.shoreline s WHERE ST_DWithin(w.geom, s.geom, 1))
) u, LATERAL ST_Dump(u.geom) d;
CREATE INDEX ON analysis.water_parts USING gist (geom);

DROP TABLE IF EXISTS analysis.wide_water CASCADE;
CREATE TABLE analysis.wide_water AS
SELECT row_number() OVER () AS wide_id, d.geom::geometry(Polygon, :crs) AS geom
FROM analysis.water_parts wp,
     LATERAL ST_Dump(ST_Buffer(ST_Buffer(wp.geom, -:narrow_width_m / 2.0, 'quad_segs=4'),
                               :narrow_width_m / 2.0, 'quad_segs=4')) d;
CREATE INDEX ON analysis.wide_water USING gist (geom);
