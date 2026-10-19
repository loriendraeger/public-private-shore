"""Load raw downloads into the PostGIS `raw` schema with ogr2ogr (and osmium for OSM).

Raw tables keep the source's CRS and attributes untouched; cleaning and reprojection
happen in sql/10_staging/.
"""

import subprocess
from pathlib import Path

from . import config

# Connection details come from the PG* environment variables (see .env.example).
PG = "PG:"
COMMON = [
    "-overwrite",
    "-lco",
    "GEOMETRY_NAME=geom",
    "-lco",
    "FID=fid",
    "-lco",
    "SPATIAL_INDEX=GIST",
    # Shapefile numeric widths are often too small for their own values; load as float.
    "-lco",
    "PRECISION=NO",
    "--config",
    "PG_USE_COPY",
    "YES",
]
OSM_LAYERS = ["points", "lines", "multipolygons"]


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def load_source(name: str, src: dict) -> None:
    path = config.REPO / src["local_path"]
    if not path.exists():
        raise FileNotFoundError(f"[{name}] {path} is missing; download it first")
    if src["format"] == "pbf":
        load_osm(path)
        return

    cmd = ["ogr2ogr", "-f", "PostgreSQL", PG, str(path)]
    if src.get("layer"):
        cmd.append(src["layer"])
    cmd += ["-nln", f"raw.{src['table']}", "-nlt", "PROMOTE_TO_MULTI", "-dim", "XY"]
    if src.get("load_srs"):
        # ESRI .prj files and compound CRSs don't map to an EPSG code on their own.
        cmd += ["-a_srs", src["load_srs"]]
    if src.get("clip_to_study_area"):
        cmd += ["-spat", *map(str, config.pipeline()["study_area"]["bbox_3071"])]
    run(cmd + COMMON)


def load_osm(pbf: Path) -> None:
    """Cut the statewide extract to the study area with osmium, then load three layers."""
    out = config.BUILD / "osm" / "dane.osm.pbf"
    out.parent.mkdir(parents=True, exist_ok=True)
    bbox = ",".join(map(str, config.pipeline()["study_area"]["bbox_4326"]))
    run(["osmium", "extract", "--bbox", bbox, "--overwrite", "-o", str(out), str(pbf)])
    for layer in OSM_LAYERS:
        run(
            [
                "ogr2ogr",
                "-f",
                "PostgreSQL",
                PG,
                str(out),
                layer,
                "-nln",
                f"raw.osm_{layer}",
                # Tags without their own column land in other_tags; store it as real hstore.
                "-lco",
                "COLUMN_TYPES=other_tags=hstore",
                *COMMON,
            ]
        )


def load(names: list[str] | None = None) -> None:
    all_sources = {k: v for k, v in config.sources().items() if v.get("table")}
    for name in names or list(all_sources):
        load_source(name, all_sources[name])
