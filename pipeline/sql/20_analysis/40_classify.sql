-- Ownership class + display label for each segment.
--   Owned segments: first matching rule in analysis.ownership_rules.
--   Gaps (no parcel within tolerance): 'row' when an OSM street is within
--   :row_road_distance_m (road right-of-way is unparceled in Dane County), else 'unknown'.

ALTER TABLE analysis.shore_segments
    ADD COLUMN IF NOT EXISTS owner_class text,
    ADD COLUMN IF NOT EXISTS owner_label text,
    ADD COLUMN IF NOT EXISTS rule_priority integer;

UPDATE analysis.shore_segments s
SET (owner_class, owner_label, rule_priority) = (
    SELECT r.class, r.label, r.priority FROM analysis.ownership_rules r
    WHERE s.owner1 ~ r.pattern
    ORDER BY r.priority LIMIT 1
)
WHERE s.owner1 IS NOT NULL;

-- '{municipality}' labels: find which municipality the owner string names, in either
-- the 'CITY OF MADISON ...' or the inverted 'MADISON, CITY OF' form. Longest place name
-- first, so a longer name wins over a shorter one it contains.
UPDATE analysis.shore_segments s
SET owner_label = coalesce((
    SELECT m.name
    FROM staging.municipalities m
    CROSS JOIN LATERAL (SELECT upper(split_part(m.name, ' of ', 1)) AS kind,
                               upper(substr(m.name, strpos(m.name, ' of ') + 4)) AS place) n
    WHERE s.owner1 LIKE n.kind || ' OF ' || n.place || '%'
       OR s.owner1 LIKE n.place || ', ' || n.kind || ' OF%'
    ORDER BY length(n.place) DESC LIMIT 1
), 'Municipal (other)')
WHERE s.owner_label = '{municipality}';

UPDATE analysis.shore_segments s
SET owner_class = CASE WHEN EXISTS (
        SELECT 1 FROM staging.osm_roads r
        WHERE r.is_street AND ST_DWithin(r.geom, s.geom, :row_road_distance_m))
    THEN 'row' ELSE 'unknown' END
WHERE s.owner1 IS NULL;

UPDATE analysis.shore_segments
SET owner_label = CASE owner_class WHEN 'row' THEN 'Road right-of-way' ELSE 'Unknown' END
WHERE owner1 IS NULL;
