-- Water polygons: county LakesPonds geometry (aligns with parcels to a few meters) plus
-- DNR 24K identity (WBIC, official name) by spatial overlap. DNR geometry is 12-25 m off
-- the parcels, so it is never used for shape.

DROP TABLE IF EXISTS staging.dnr_waterbody CASCADE;
CREATE TABLE staging.dnr_waterbody AS
SELECT
    fid AS dnr_id,
    waterbody_wbic AS wbic,
    nullif(trim(waterbody_name), '') AS name,
    hydrotype,                                    -- coded domain: 706 Lake/Pond, 602 Stream/River, ...
    ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))::geometry(MultiPolygon, :crs) AS geom
FROM raw.dnr_waterbody;
CREATE INDEX ON staging.dnr_waterbody USING gist (geom);

-- HYDTYPE is Lake / River / Island, and NULL for 9 polygons, including the main Yahara
-- River polygon (202 ha). Island polygons are land filling holes in water, so drop them
-- with IS DISTINCT FROM (a plain <> would also drop the NULLs).
DROP TABLE IF EXISTS staging.water CASCADE;
CREATE TABLE staging.water AS
SELECT
    fid AS water_id,
    nullif(trim(name), '') AS county_name,
    hydtype,
    ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Transform(geom, :crs)), 3))::geometry(MultiPolygon, :crs) AS geom
FROM raw.county_lakesponds
WHERE hydtype IS DISTINCT FROM 'Island';

ALTER TABLE staging.water ADD PRIMARY KEY (water_id);
CREATE INDEX ON staging.water USING gist (geom);

-- Identity: the DNR waterbody covering the largest share of each county polygon.
-- Small ponds may have no DNR match; they keep only the county name (if any).
ALTER TABLE staging.water ADD COLUMN wbic integer, ADD COLUMN dnr_name text;
UPDATE staging.water w
SET wbic = m.wbic, dnr_name = m.name
FROM (
    SELECT DISTINCT ON (w.water_id) w.water_id, d.wbic, d.name
    FROM staging.water w
    JOIN staging.dnr_waterbody d ON ST_Intersects(w.geom, d.geom)
    ORDER BY w.water_id, ST_Area(ST_Intersection(w.geom, d.geom)) DESC
) m
WHERE w.water_id = m.water_id;

ALTER TABLE staging.water ADD COLUMN name text
    GENERATED ALWAYS AS (coalesce(county_name, dnr_name)) STORED;
ALTER TABLE staging.water ADD COLUMN area_m2 double precision
    GENERATED ALWAYS AS (ST_Area(geom)) STORED;
