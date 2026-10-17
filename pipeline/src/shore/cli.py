"""`shore <command>`: the pipeline entry point, called by the Makefile."""

from typing import Annotated

import typer

from . import export as export_mod
from . import load as load_mod
from . import sqlrun
from . import stats as stats_mod

app = typer.Typer(no_args_is_help=True, add_completion=False)


@app.command()
def load(
    sources: Annotated[
        list[str] | None, typer.Argument(help="sources.toml sections (default: all)")
    ] = None,
):
    """Load raw downloads into the PostGIS `raw` schema."""
    load_mod.load(sources)


@app.command()
def sql(
    stage: Annotated[str, typer.Argument(help="pipeline/sql directory, e.g. 10_staging")],
    set_: Annotated[
        list[str] | None,
        typer.Option("--set", help="override a pipeline.toml value: key=value (repeatable)"),
    ] = None,
):
    """Run one SQL stage."""
    if stage not in sqlrun.stages():
        raise typer.BadParameter(f"unknown stage; choose from {sqlrun.stages()}")
    overrides = dict(kv.split("=", 1) for kv in set_ or [])
    sqlrun.run_stage(stage, overrides)


@app.command()
def export():
    """Write every view in the `export` schema to data/build/export/<view>.geojsonl."""
    export_mod.export_views()


@app.command()
def stats():
    """Write site/public/data/stats.json from the export.stats_* views."""
    stats_mod.stats()


@app.command()
def tiles():
    """Build site/public/data/shore.pmtiles from data/build/export/*.geojsonl."""
    export_mod.tiles()


@app.command()
def basemap():
    """Extract the Dane County basemap from the Protomaps build in sources.toml."""
    export_mod.basemap()


@app.command()
def compare(
    set_: Annotated[list[str], typer.Option("--set", help="key=value, e.g. snap_tolerance_m=12")],
    name: Annotated[str, typer.Option(help="tile layer name for the alternative")] = "shore_alt",
):
    """Export the shore layer once more under alternative settings, as an extra layer
    for comparing on the map; then restore the analysis to the configured settings."""
    overrides = dict(kv.split("=", 1) for kv in set_)
    sqlrun.run_stage("20_analysis", overrides)
    sqlrun.run_stage("30_export")
    export_mod.export_view("shore", name)
    sqlrun.run_stage("20_analysis")


if __name__ == "__main__":
    app()
