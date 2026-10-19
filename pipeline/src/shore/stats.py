"""export.stats_* views -> site/public/data/stats.json, the scorecard's data.

Tidy rows (municipality x waterbody x category, meters); the site does the
aggregation. Shape must match site/src/lib/contract.ts (`Stats`).
"""

import datetime
import json
import re

import psycopg
from psycopg.rows import dict_row

from . import config
from .export import SITE_DATA

# Must match site/.prettierrc.json, so stats.json passes `npm run check` as written.
PRETTIER_PRINT_WIDTH = 100

# Sources whose vintage the site shows (sources.toml sections).
VINTAGE_SOURCES = ["parcels", "hydro_county", "hydro", "municipalities", "osm", "population"]

# pipeline.toml settings the site quotes in its text (About page, tooltips), so the
# words follow the analysis.
SITE_SETTINGS = ["snap_tolerance_m", "narrow_width_m", "pond_min_area_m2"]


def stats() -> None:
    # Connection details come from the PG* environment variables.
    with psycopg.connect("", row_factory=dict_row) as conn:
        munis = conn.execute("SELECT * FROM export.stats_municipalities ORDER BY name").fetchall()
        shore = conn.execute(
            "SELECT * FROM export.stats_shore ORDER BY muni_id, waterbody, category"
        ).fetchall()

    src = config.sources()
    out = {
        "generated": datetime.date.today().isoformat(),
        "sources": {
            name: {
                "name": src[name]["name"],
                "url": src[name].get("landing", src[name]["url"]),
                "retrieved": src[name]["retrieved"],
            }
            for name in VINTAGE_SOURCES
        },
        "settings": {key: setting(key) for key in SITE_SETTINGS},
        "municipalities": munis,
        "shore": shore,
    }
    SITE_DATA.mkdir(parents=True, exist_ok=True)
    path = SITE_DATA / "stats.json"
    path.write_text(prettier_json(out))
    print(f"wrote {path.relative_to(config.REPO)}: {len(munis)} municipalities, "
          f"{len(shore)} rows")


def setting(key: str):
    """A pipeline.toml value by key, whatever its section (keys are unique; see
    config.psql_vars)."""
    for values in config.pipeline().values():
        if key in values:
            return values[key]
    raise KeyError(f"{key!r} not in config/pipeline.toml")


# A multi-line array of numbers, with the text before it on its line and the comma after.
_NUMBER_ARRAY = re.compile(
    r"^(?P<lead>.*)\[\n(?P<body>(?:[ ]*-?[0-9][0-9.eE+-]*,?\n)+)[ ]*\](?P<tail>,?)$", re.M
)


def prettier_json(obj) -> str:
    """JSON laid out the way Prettier formats it: 2-space indent, objects expanded,
    number arrays on one line when they fit the print width. Other array shapes
    (strings, mixed) aren't in stats.json; extend this if they appear."""

    def collapse(m: re.Match) -> str:
        items = [line.strip().rstrip(",") for line in m["body"].splitlines()]
        line = f"{m['lead']}[{', '.join(items)}]{m['tail']}"
        return line if len(line) <= PRETTIER_PRINT_WIDTH else m[0]

    return _NUMBER_ARRAY.sub(collapse, json.dumps(obj, indent=2, ensure_ascii=False)) + "\n"
