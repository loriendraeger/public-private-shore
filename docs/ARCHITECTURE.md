# Architecture

How the code is put together: what each piece does, what it reads and writes, and
where to make a change. For *why* the project exists and the decisions behind it, see
[AGENTS.md](../AGENTS.md). For dataset details, see [config/sources.toml](../config/sources.toml).

Status markers: **built** pieces exist and run; **planned** pieces are designed but not
written yet. Keep this file current when a piece is added or changes shape.

## The big picture

```
data/raw/ (downloads, by hand)
   │  shore load         ogr2ogr / osmium            built
   ▼
PostGIS  raw ──► staging ──► analysis ──► export     SQL stages, built
   │  shore export (built) / stats (planned)
   ▼
data/build/export/*.geojsonl ──► tippecanoe ──► site/public/data/shore.pmtiles   built
Protomaps planet build ──► pmtiles extract ──► site/public/data/basemap.pmtiles built
                                                site/public/data/stats.json  planned
   │
   ▼
site/ (Vite + Solid + MapLibre) ──► GitHub Pages                            built
```

Two halves meet at `site/public/data/`:

- **The pipeline** runs locally, by hand, and is slow. It turns raw public datasets
  into committed files.
- **The site** is static and only reads those committed files. CI never runs the
  pipeline.

## Running it

```sh
cp .env.example .env     # once
make staging             # db-up → init → load → staging (stamps skip finished steps)
make analysis            # shoreline → segments → class → municipality → access
make tiles               # export views → GeoJSONSeq → site/public/data/shore.pmtiles
make basemap             # Protomaps extract → site/public/data/basemap.pmtiles (~29 MB)
make compare SET=snap_tolerance_m=12   # extra `shore_alt` layer for side-by-side checks
make test                # unit tests (no DB)
make psql                # SQL shell in the database
make db-reset            # wipe the database volume and all stamps
```

Every `make` target runs `shore <command>` inside the **pipeline container**, so the
host only needs Docker and Make.

## Components

### `docker-compose.yml`: two services

| Service | What | Notes |
|---|---|---|
| `db` | PostGIS 17 / 3.5 (`imresamu/postgis`, a multi-arch build of the official image) | Data lives in the `pgdata` volume. Port 5432 on the host. |
| `pipeline` | The tools container built from `pipeline/Dockerfile` | `profiles: [tools]`, so `docker compose up` doesn't start it. The repo is bind-mounted at `/work`. `PGHOST=db`. |

Connection settings come from `.env` (`PG*` variables, read by psql, ogr2ogr and
psycopg alike).

### `pipeline/Dockerfile`: pinned tools

GDAL/OGR 3.13 (base image), psql, osmium-tool, tippecanoe (built from source),
pmtiles CLI, uv, and a uv-managed Python 3.12. The Python venv lives at `/opt/venv`,
outside the bind mount, so it never collides with anything on the host. To bump a
tool, change its `ARG`/tag and run `make image`.

### `Makefile`: orchestration

Recipes are thin, typically `$(RUN) <cmd>`. Make can't see inside PostGIS, so each DB
stage touches a **stamp** in `data/build/.stamps/<stage>`:

```
init ──► load ──► staging ──► analysis ──► export ──► tiles      (basemap, compare: standalone)
```

A stamp depends on its stage's SQL files, on `config/*`, and on the previous stamp.
Editing `40_parcels.sql` reruns staging and everything after it, but not `load`.
`load` reruns only when `config/sources.toml` changes.

### `config/`: every tunable

| File | Read by | Contents |
|---|---|---|
| `pipeline.toml` | `shore sql` → psql variables | analysis CRS, study-area bboxes, waterbodies in scope, snap tolerance |
| `sources.toml` | `shore load`, humans | per dataset: path, layer, CRS, `table`, license, recon notes |
| `ownership_rules.csv` | `20_analysis/10_ownership_rules.sql`, unit tests | ordered regex over the uppercased owner name → class + label. First match by `priority` wins. Label `{municipality}` resolves to the municipality named in the owner string. Patterns must work in both Postgres and Python regex: **no `\b`** (backspace in Postgres). |
| `access_defaults.csv` | `60_access.sql` | ownership class → default access |
| `access_osm.csv` | `60_access.sql` | OSM feature category → access. `public_only=true` (piers) = evidence only on non-private land |
| `access_overrides.csv` | `60_access.sql` | hand fixes: `lon,lat,access,note`; applies to the nearest segment within 20 m |

**pipeline.toml → SQL:** `shore sql` flattens every key into a psql variable, ignoring
the section (`[analysis] crs = 3071` becomes `-v crs=3071`). Keys must therefore be
unique across sections. Lists become comma-joined strings. SQL refers to them as
`:crs` (bare) or `:'waterbodies'` (quoted string literal) and splits lists with
`string_to_array(:'waterbodies', ',')`. **SQL never hardcodes a CRS, tolerance or bbox.**

### `pipeline/src/shore/`: the Python glue

Python handles orchestration; geometry logic belongs in SQL.

| Module | Status | Role |
|---|---|---|
| `cli.py` | built | Typer app; the `shore` console script. Commands: `load`, `sql <stage> [--set key=value]`. `--set` overrides a pipeline.toml value for one run (e.g. `--set snap_tolerance_m=12` to compare tolerances) without touching config. |
| `config.py` | built | Reads `config/*.toml` (cached); `psql_vars()` flattens pipeline.toml; repo paths (`REPO`, `SQL_DIR`, `BUILD`). |
| `load.py` | built | For each `sources.toml` entry with a `table`: `ogr2ogr` into `raw.<table>`. It honors `load_srs` (assigns an EPSG code when the .prj is ESRI-only or compound) and `clip_to_study_area`. OSM: `osmium extract` to the bbox, then three ogr2ogr layers with `other_tags` as hstore. |
| `sqlrun.py` | built | Runs `pipeline/sql/<stage>/*.sql` in filename order with `psql -v ON_ERROR_STOP=1` and the config variables. Runs from the repo root so `\copy` can use `config/...` paths. |
| `download.py` | planned | Fetch sources (downloads are currently by hand) |
| `export.py` | built | `export`: every view in the `export` schema → `data/build/export/<view>.geojsonl`. `tiles`: every `.geojsonl` there becomes a layer of `shore.pmtiles` (zooms from `[tiles]`). `basemap`: `pmtiles extract` of the Protomaps build URL in sources.toml. `compare` (in cli.py) reruns analysis with `--set` overrides, exports `shore` as `shore_alt`, then restores. |
| `stats.py` | planned | analysis tables → `stats.json` |

### `pipeline/sql/`: the analysis, one directory per schema

Each directory writes **only** to its own schema. Files run in name order; prefixes
step by 10 so steps can be slotted in. Every file is idempotent (`DROP ... IF EXISTS`
then `CREATE`), so rerunning is always safe.

#### `00_init/` → extensions and schemas (built)

| File | Creates |
|---|---|
| `10_schemas.sql` | extensions `postgis`, `hstore`; schemas `raw`, `staging`, `analysis`, `export` |

#### `raw` schema: written by `shore load`, not SQL

| Table | Source | CRS |
|---|---|---|
| `raw.parcels` | SCO V12 parcels | 3071 |
| `raw.dnr_waterbody` | DNR 24K waterbody polygons, clipped to Dane bbox | 3071 |
| `raw.county_lakesponds` | Dane County LakesPonds | 7599 (US ft) |
| `raw.municipalities` | Dane County Municipal Boundaries | 7599 (US ft) |
| `raw.osm_points` / `osm_lines` / `osm_multipolygons` | Geofabrik extract → osmium bbox | 4326 |

#### `10_staging/` → cleaned, valid, in `:crs` (built)

| File | Creates | Key points |
|---|---|---|
| `10_municipalities.sql` | `staging.municipalities` (muni_id, name, muni_type, fipscode, geom) | `C/V/T` → `city/village/town`; MakeValid |
| `20_county_boundary.sql` | `staging.county_boundary` | union of municipalities (they tile the county); the clip mask |
| `30_hydro.sql` | `staging.dnr_waterbody`, `staging.water` (water_id, name, wbic, hydtype, area_m2, geom) | county geometry + DNR WBIC by largest overlap; drops `Island` but keeps NULL hydtype (the Yahara) |
| `40_parcels.sql` | `staging.parcels` (parcel_id, owner1/2, placename, auxclass, propclass, geom) | owner names uppercased and trimmed; **stay in DB, never exported** |
| `50_osm.sql` | `staging.osm_access_features` (category, access, operator), `staging.osm_roads` (highway, is_street) | categories: park, nature_reserve, beach, swimming, slipway, marina, boat_rental, pier, fishing |

#### `20_analysis/` → shoreline to classified segments (built)

Everything ends up in **`analysis.shore_segments`**, one row per stretch of shore with
one owner in one municipality:
`segment_id, shore_id, waterbody, wbic, owner1 (raw, never exported), parcel_ids,
muni_id, muni_name, muni_type, owner_class, owner_label, rule_priority, access,
access_source, access_note, length_m, geom`.

| File | Creates / updates | How |
|---|---|---|
| `10_ownership_rules.sql` | `analysis.ownership_rules` | `\copy` from the CSV |
| `20_shoreline.sql` | `analysis.shoreline` (shore_id, waterbody, wbic, geom) | In-scope water (`:'waterbodies'`) plus touching water polygons → `ST_Union` (seams dissolve, island rings survive) → `ST_Boundary`, kept only where it bounds in-scope water |
| `30_shore_segments.sql` | `analysis.shore_steps`, `analysis.shore_parcels`, `analysis.shore_segments` | **Sampling:** steps of `:sample_step_m`; each step's midpoint → nearest parcel *polygon* within `:snap_tolerance_m` (none = gap). Consecutive steps with the same (owner name, parcel's municipality) collapse into a segment (gaps-and-islands), with exact `ST_LineSubstring` geometry. Runs that wrap around a closed ring's start are merged. |
| `40_classify.sql` | `owner_class`, `owner_label` | First matching rule; gaps → `row` if an OSM street is within `:row_road_distance_m`, else `unknown` |
| `50_municipality.sql` | `muni_id` (gaps), `muni_name`, `muni_type` | Owned segments: the municipality containing the parcel (land side). Gaps: the municipality covering most land within 20 m. |
| `60_access.sql` | `access`, `access_source`, `access_note` | default (class) → osm (area features must cover ≥ half the segment within `:access_evidence_distance_m`; explicit `access=*` tags win; the most open applies) → street_end (`row` segments) → override |

Known rough edges (milestone 2): the Arboretum is two owner strings, so it isn't one
segment; private land inside an OSM nature reserve becomes `open` (by design; fix
exceptions with overrides).

#### `30_export/` → views for tiles (built)

Views, so they're always current with `analysis`. Each view = one tile layer.

| File | View / tile layer | Attributes |
|---|---|---|
| `10_shore.sql` | `shore` (lines) | segment_id, waterbody, owner_class, owner_label, access, access_source, access_note, muni_name, muni_type, length_m |
| `20_parks.sql` | `parks` (polygons) | feature_id, name, category (park / nature_reserve), within 100 m of in-scope shore |
| (via `make compare`) | `shore_alt` | same as `shore`, under alternative settings |

### `site/`: the map (built)

Vite 8 + Solid + TypeScript 7, MapLibre GL 6, `pmtiles`, `@protomaps/basemaps`.
Node 24 (`site/.nvmrc`). It reads only `site/public/data/`.

```sh
cd site && nvm use && npm install
npm run dev        # http://localhost:5173/public-private-land/
npm run build      # tsc --noEmit + vite build → site/dist/
```

| File | Role |
|---|---|
| `src/lib/contract.ts` | Frontend half of the data contract: tile layer names, `ShoreProps`, class/access unions |
| `src/state/store.ts` | Solid signals: `colorBy` (owner/access), `showAlt`, `hasAlt`, `selected` |
| `src/map/MapView.tsx` | Creates the map **once**. Registers the `pmtiles://` protocol; basemap from `@protomaps/basemaps` (light/dark picked at load from the OS setting); layers: parks (dashed outline), shore casing + line + invisible wide hit line, selection outline. Signals update paint/visibility/filter in place. |
| `src/map/colors.ts` | Colors and MapLibre `match` expressions. Ownership folds 11 classes into 4 groups (a map is an all-pairs view, where only 3 hues stay CVD-safe). Access uses the status palette with icons. Validated with the dataviz validator. |
| `src/components/Panel.tsx` | Title, color-by toggle, legend, tolerance toggle (only if `shore_alt` exists), selected-segment details, disclaimer |
| `vite.config.ts` | `base: '/public-private-land/'`; `worker.format: 'es'` |

**MapLibre worker gotcha:** MapLibre 6 loads its Web Worker from a file next to its own
module, which breaks once Vite moves the module (pre-bundling in dev, bundling in
build). `MapView.tsx` imports the worker with `?worker&url` and passes it to
`setWorkerUrl()`.

### `.github/workflows/deploy.yml`

`npm ci` → `npm run build` → `upload-pages-artifact` → `deploy-pages`. It's **manual only**
(`workflow_dispatch`) while `site/public/data/` is gitignored; restore the `push`
trigger when the data is committed. The repo's Pages source must be set to
"GitHub Actions".

## The data contract

These must change together:

1. `pipeline/sql/30_export/*`: tile layer names and attributes, stats shape
2. `pipeline/src/shore/stats.py`: `stats.json` writer
3. `site/src/lib/`: TypeScript types for both

Attributes that may leave the database: ownership class, owner **label**, access,
access source, municipality, length. Raw owner names never do.

## Where do I change...?

| I want to... | Edit |
|---|---|
| change the CRS, tolerance or scope | `config/pipeline.toml` |
| add or fix a dataset | `config/sources.toml` (add `table` to have it loaded), then `make load` |
| change how a dataset is cleaned | `pipeline/sql/10_staging/<n>_<dataset>.sql` |
| add an analysis step | a new numbered file in `pipeline/sql/20_analysis/` |
| reclassify an owner | `config/ownership_rules.csv`, plus a case in `pipeline/tests/unit/test_ownership_rules.py` |
| fix one segment's access by hand | `config/access_overrides.csv` |
| try a different tolerance | `shore sql 20_analysis --set snap_tolerance_m=12` |
| add a pipeline command | `pipeline/src/shore/cli.py` + a Makefile target |
| bump a tool version | `pipeline/Dockerfile`, then `make image` |
