-- Ownership rules as data: ordered regexes over the (uppercased) owner name.
-- The first matching rule by priority wins. Patterns are POSIX/ARE regexes, written to
-- also be valid Python regexes (the unit tests use Python). In ARE, \b is backspace,
-- not a word boundary, so rules avoid it.
DROP TABLE IF EXISTS analysis.ownership_rules CASCADE;
CREATE TABLE analysis.ownership_rules (
    priority integer PRIMARY KEY,
    pattern  text NOT NULL,
    class    text NOT NULL,
    label    text NOT NULL,   -- '{municipality}' = resolve from the owner string
    note     text
);

\copy analysis.ownership_rules FROM 'config/ownership_rules.csv' WITH (FORMAT csv, HEADER true)
