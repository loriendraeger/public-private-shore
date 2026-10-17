"""Export views -> GeoJSONSeq -> tippecanoe -> PMTiles, and the basemap extract.

Each view in the `export` schema becomes one tile layer of the same name.
"""

import subprocess
from pathlib import Path

from . import config
from .load import run

EXPORT_DIR = config.BUILD / "export"
SITE_DATA = config.REPO / "site" / "public" / "data"


def export_view(view: str, out_name: str | None = None) -> Path:
    """Write export.<view> as newline-delimited GeoJSON (what tippecanoe reads fastest)."""
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    out = EXPORT_DIR / f"{out_name or view}.geojsonl"
    out.unlink(missing_ok=True)
    run(["ogr2ogr", "-f", "GeoJSONSeq", str(out), "PG:", f"export.{view}",
         "-lco", "COORDINATE_PRECISION=7"])   # ~1 cm at this latitude
    return out


def export_views() -> list[Path]:
    """Export every export view that has geometry (the tile layers)."""
    views = subprocess.run(
        ["psql", "-X", "-At", "-c",
         # Views with a geometry column are tile layers; the rest (stats_*) feed stats.json.
         "SELECT f_table_name FROM geometry_columns WHERE f_table_schema = 'export' "
         "ORDER BY f_table_name"],
        check=True, capture_output=True, text=True,
    ).stdout.split()
    return [export_view(v) for v in views]


def tiles() -> None:
    """Build one PMTiles file per [tiles.files] entry from data/build/export/*.geojsonl.
    Missing layers are skipped (e.g. shore_alt only exists after `shore compare`)."""
    t = config.pipeline()["tiles"]
    if not any(EXPORT_DIR.glob("*.geojsonl")):
        raise SystemExit("nothing exported yet; run `shore export` first")
    assigned = {layer for layers in t["files"].values() for layer in layers}
    unassigned = sorted(f.stem for f in EXPORT_DIR.glob("*.geojsonl") if f.stem not in assigned)
    if unassigned:
        raise SystemExit(f"exported layers not assigned to a file in [tiles.files]: {unassigned}")
    SITE_DATA.mkdir(parents=True, exist_ok=True)
    for name, layers in t["files"].items():
        cmd = ["tippecanoe", "-o", str(SITE_DATA / f"{name}.pmtiles"), "--force",
               "-Z", str(t["minzoom"]), "-z", str(t["maxzoom"]),
               # Shore lines are the point of the map; never drop them to fit a tile budget.
               "--no-feature-limit", "--no-tile-size-limit",
               "--attribution", t["attribution"]]
        for layer in layers:
            f = EXPORT_DIR / f"{layer}.geojsonl"
            if f.exists():
                cmd += ["-L", f"{layer}:{f}"]
        run(cmd)


def basemap() -> None:
    """Cut a basemap extract from a Protomaps planet build: the bounding rectangle of the
    study area plus a margin. Uses HTTP range requests, so only the needed tiles are downloaded.
    Needs `analysis.study_area` (run the analysis first)."""
    b = config.sources()["basemap"]
    t = config.pipeline()["tiles"]
    region = config.BUILD / "basemap_region.geojson"
    region.parent.mkdir(parents=True, exist_ok=True)
    region.unlink(missing_ok=True)
    # The study area plus a margin, as its bounding rectangle: the site limits the camera
    # to the extract's (rectangular) bounds, so the extract must fill that whole rectangle.
    # An irregular region would leave blank corners.
    sql = (f"SELECT ST_Envelope(ST_Buffer(geom, {t['basemap_buffer_m']})) AS geom "
           f"FROM analysis.study_area")
    run(["ogr2ogr", "-f", "GeoJSON", str(region), "PG:", "-sql", sql, "-t_srs", "EPSG:4326"])
    SITE_DATA.mkdir(parents=True, exist_ok=True)
    run(["pmtiles", "extract", b["url"], str(SITE_DATA / "basemap.pmtiles"),
         f"--region={region}", f"--maxzoom={t['basemap_maxzoom']}"])
