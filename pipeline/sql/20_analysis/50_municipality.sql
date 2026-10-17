-- Municipality name + type for each segment, from the LAND side.
-- Owned segments already carry muni_id from their parcel (30_shore_segments.sql).
-- Gaps have no parcel: use the municipality covering most of the land within 20 m of
-- the segment (buffer minus water), since the water itself belongs to some municipality.

UPDATE analysis.shore_segments s
SET muni_id = (
    SELECT m.muni_id
    FROM staging.municipalities m,
         LATERAL (SELECT ST_Difference(
                     ST_Buffer(s.geom, 20),
                     (SELECT ST_Union(w.geom) FROM staging.water w WHERE ST_DWithin(w.geom, s.geom, 20))
                 ) AS land) l
    WHERE ST_Intersects(m.geom, l.land)
    ORDER BY ST_Area(ST_Intersection(m.geom, l.land)) DESC
    LIMIT 1
)
WHERE s.muni_id IS NULL;

-- The study area is defined by municipality (pipeline.toml [study_area]), judged from
-- the land side: shore inside the study area whose adjacent land belongs to an excluded
-- municipality (e.g. where a study-area boundary follows a shoreline) is dropped.
DELETE FROM analysis.shore_segments
WHERE muni_id IS NULL OR muni_id NOT IN (SELECT muni_id FROM analysis.study_area_munis);

ALTER TABLE analysis.shore_segments
    ADD COLUMN IF NOT EXISTS muni_name text,
    ADD COLUMN IF NOT EXISTS muni_type text;

UPDATE analysis.shore_segments s
SET muni_name = m.name, muni_type = m.muni_type
FROM staging.municipalities m
WHERE m.muni_id = s.muni_id;
