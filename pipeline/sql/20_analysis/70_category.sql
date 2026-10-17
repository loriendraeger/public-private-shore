-- Scorecard category per segment: the one attribute the analysis (stats, scorecard)
-- uses, derived from ownership class + access via config/categories.csv. Any
-- (class, access) pair not listed there, including every `unknown` access, is `unknown`.
-- Owner labels and access notes stay on the segment as map-only detail.

DROP TABLE IF EXISTS analysis.categories;
CREATE TABLE analysis.categories (
    owner_class text, access text, category text NOT NULL, note text,
    PRIMARY KEY (owner_class, access)
);
\copy analysis.categories FROM 'config/categories.csv' WITH (FORMAT csv, HEADER true)

ALTER TABLE analysis.shore_segments ADD COLUMN IF NOT EXISTS category text;

UPDATE analysis.shore_segments s
SET category = coalesce(
    (SELECT c.category FROM analysis.categories c
     WHERE c.owner_class = s.owner_class AND c.access = s.access),
    'unknown');
