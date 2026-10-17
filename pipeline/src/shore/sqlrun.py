"""Run pipeline/sql/<stage>/*.sql in filename order through psql.

Values from config/pipeline.toml are passed as psql variables, so SQL writes :crs or
:'name' instead of hardcoding them.
"""

import os
import subprocess

from . import config


def stages() -> list[str]:
    return sorted(p.name for p in config.SQL_DIR.iterdir() if p.is_dir())


def run_stage(stage: str, overrides: dict[str, str] | None = None) -> None:
    """Run a stage. `overrides` replace pipeline.toml values for this run only, for
    experiments such as comparing snap tolerances."""
    files = sorted((config.SQL_DIR / stage).glob("*.sql"))
    if not files:
        raise FileNotFoundError(f"no SQL files in {config.SQL_DIR / stage}")
    values = config.psql_vars()
    for key in overrides or {}:
        if key not in values:
            raise SystemExit(f"--set {key}: not a pipeline.toml key")
    values |= overrides or {}
    variables = [arg for k, v in values.items() for arg in ("-v", f"{k}={v}")]
    for f in files:
        print(f"== {stage}/{f.name}", flush=True)
        # Run from the repo root so \copy can use repo-relative paths like config/x.csv.
        result = subprocess.run(
            ["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", *variables, "-f", str(f)],
            cwd=config.REPO,
            # Hide the NOTICEs that every idempotent DROP ... IF EXISTS prints.
            env={**os.environ, "PGOPTIONS": "-c client_min_messages=warning"},
        )
        if result.returncode != 0:
            # psql already printed the error with file and line; no traceback needed.
            raise SystemExit(f"stage {stage} failed in {f.name}")
