"""export.stats_* views -> site/public/data/stats.json, the scorecard's data.

Tidy rows (municipality x waterbody x category, meters); the site does the
aggregation. Shape must match site/src/lib/contract.ts (`Stats`).
"""

import datetime
import json

import psycopg
from psycopg.rows import dict_row

from . import config
from .export import SITE_DATA

# Sources whose vintage the site shows (sources.toml sections).
VINTAGE_SOURCES = ["parcels", "hydro_county", "hydro", "municipalities", "osm", "population"]


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
            name: {"name": src[name]["name"], "retrieved": src[name]["retrieved"]}
            for name in VINTAGE_SOURCES
        },
        "municipalities": munis,
        "shore": shore,
    }
    SITE_DATA.mkdir(parents=True, exist_ok=True)
    path = SITE_DATA / "stats.json"
    path.write_text(json.dumps(out, separators=(",", ":"), ensure_ascii=False) + "\n")
    print(f"wrote {path.relative_to(config.REPO)}: {len(munis)} municipalities, "
          f"{len(shore)} rows")
