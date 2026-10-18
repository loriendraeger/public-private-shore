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
   │  shore export / shore stats                    built
   ▼
data/build/export/*.geojsonl ──► tippecanoe ──► site/public/data/{shore,context}.pmtiles   built
Protomaps planet build ──► pmtiles extract (study-area region) ──► site/public/data/basemap.pmtiles built
export.stats_* views ──► stats.py ──► site/public/data/stats.json     built
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
make tiles               # export views → GeoJSONSeq → site/public/data/{shore,context}.pmtiles
make stats               # export.stats_* views → site/public/data/stats.json (scorecard data)
make basemap             # Protomaps extract (study-area bounding box + 2 km) → site/public/data/basemap.pmtiles (~22 MB)
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
| `pipeline.toml` | `shore sql` → psql variables | study-area municipalities, load bboxes, analysis CRS, snap tolerance, tile files |
| `sources.toml` | `shore load`, humans | per dataset: path, layer, CRS, `table`, license, recon notes |
| `ownership_rules.csv` | `20_analysis/10_ownership_rules.sql`, unit tests | ordered regex over the uppercased owner name → class + label. First match by `priority` wins. Label `{municipality}` resolves to the municipality named in the owner string. Patterns must work in both Postgres and Python regex: **no `\b`** (backspace in Postgres). |
| `access_defaults.csv` | `60_access.sql` | ownership class → default access |
| `access_osm.csv` | `60_access.sql` | OSM feature category → access. `public_only=true` (piers) = evidence only on non-private land |
| `access_overrides.csv` | `60_access.sql` | hand fixes: `lon,lat,access,note`; applies to the nearest segment within 20 m |
| `categories.csv` | `70_category.sql` | (ownership class, access) → scorecard category; unlisted pairs → `unknown` |

**pipeline.toml → SQL:** `shore sql` flattens every key into a psql variable, ignoring
the section (`[analysis] crs = 3071` becomes `-v crs=3071`). Keys must therefore be
unique across sections. Lists become comma-joined strings. SQL refers to them as
`:crs` (bare) or `:'waterbodies'` (quoted string literal) and splits lists with
`string_to_array(:'waterbodies', ',')`. **SQL never hardcodes a CRS, tolerance or bbox.**

**Performance notes** (`shore sql` prints per-file times and statements ≥ 1 s; the full
log is `data/build/timings/<stage>.tsv`). The analysis stage takes ~50 s. Lessons:
- Big polygons (Lake Mendota is ~40k vertices) make `ST_DWithin`/`ST_Buffer` slow.
  `ST_Subdivide` them into small pieces first.
- Pieces, sample points and anything joined spatially go in a **table with a GiST
  index**, not a CTE (CTEs have no index, so the join becomes a nested loop).
- Join on expressions the index can use (compute keys from one side only).
- Postgres runs each statement on one core; `UPDATE ... SET x = (subquery)` never
  runs in parallel. Docker CPUs are not the bottleneck.

### `pipeline/src/shore/`: the Python glue

Python handles orchestration; geometry logic belongs in SQL.

| Module | Status | Role |
|---|---|---|
| `cli.py` | built | Typer app; the `shore` console script. Commands: `load`, `sql <stage> [--set key=value]`. `--set` overrides a pipeline.toml value for one run (e.g. `--set snap_tolerance_m=12` to compare tolerances) without touching config. |
| `config.py` | built | Reads `config/*.toml` (cached); `psql_vars()` flattens pipeline.toml; repo paths (`REPO`, `SQL_DIR`, `BUILD`). |
| `load.py` | built | For each `sources.toml` entry with a `table`: `ogr2ogr` into `raw.<table>`. It honors `load_srs` (assigns an EPSG code when the .prj is ESRI-only or compound) and `clip_to_study_area`. OSM: `osmium extract` to the bbox, then three ogr2ogr layers with `other_tags` as hstore. |
| `sqlrun.py` | built | Runs `pipeline/sql/<stage>/*.sql` in filename order with `psql -v ON_ERROR_STOP=1` and the config variables. Runs from the repo root so `\copy` can use `config/...` paths. |
| `download.py` | planned | Fetch sources (downloads are currently by hand) |
| `export.py` | built | `export`: every view in the `export` schema → `data/build/export/<view>.geojsonl`. `tiles`: builds one PMTiles file per `[tiles.files]` entry in pipeline.toml (`shore` = analysis output, so its bounds are the study area and the map fits to them; `context` = county-wide reference layers). Every exported layer must be assigned to a file. `basemap`: writes the bounding rectangle of the study area (buffered by `basemap_buffer_m`) to `data/build/basemap_region.geojson` and runs `pmtiles extract --region` on the Protomaps build URL in sources.toml, up to `basemap_maxzoom` (15: 22 MB; 14 would be ~10 MB). A rectangle, because the site limits the camera to the extract's bounds (`setMaxBounds`), so the extract must fill them. `compare` (in cli.py) reruns analysis with `--set` overrides, exports `shore` as `shore_alt`, then restores. |
| `stats.py` | built | `stats`: `export.stats_municipalities` + `export.stats_shore` → `site/public/data/stats.json` (psycopg; source vintages from sources.toml). Shape = `Stats` in `site/src/lib/contract.ts`. `export_views` skips these views because they have no geometry. |

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
| `raw.population` | WI DOA municipal population estimates (xlsx; generic `field1..10` columns, header in row 4) | none |

#### `10_staging/` → cleaned, valid, in `:crs` (built)

| File | Creates | Key points |
|---|---|---|
| `10_municipalities.sql` | `staging.municipalities` (muni_id, name, muni_type, fipscode, geom) | `C/V/T` → `city/village/town`; MakeValid |
| `20_county_boundary.sql` | `staging.county_boundary` | union of municipalities (they tile the county); the clip mask |
| `30_hydro.sql` | `staging.dnr_waterbody`, `staging.osm_water_names`, `staging.water` (water_id, county_name, dnr_name, osm_name, water_class, name, wbic, hydtype, area_m2, geom) | county geometry + DNR WBIC by largest overlap. `water_class`: `named` (county/DNR name, or an OSM-named unnamed piece ≥ `:pond_min_area_m2` touching named water), `pond` (other standalone water ≥ `:pond_min_area_m2`; name = OSM name or 'Unnamed pond'), NULL = out of scope. Drops `Island` but keeps NULL hydtype (the Yahara) |
| `40_parcels.sql` | `staging.parcels` (parcel_id, owner1/2, placename, auxclass, propclass, geom) | owner names uppercased and trimmed; **stay in DB, never exported** |
| `60_population.sql` | `staging.population` (muni_id, name, pop_estimate, pop_census_2020) | Dane County rows; `C Madison3` → `City of Madison` (trailing digits are footnotes); fails if any municipality has no population |
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
| `15_study_area.sql` | `analysis.study_area_munis`, `analysis.study_area` | Municipalities named in `[study_area] municipalities` (fails on unknown names) and their union |
| `20_shoreline.sql` | `analysis.in_scope_water`, `in_scope_pieces` (ST_Subdivide'd, indexed), `water_union`, `islands` (island_id, area_m2, bridged, geom), `shoreline` (shore_id, waterbody, wbic, geom) | In scope = every **named** water polygon touching the study area. All water near it is `ST_Union`ed (seams dissolve). Islands = holes in that union; they're dropped unless `bridged` (an OSM road/path crosses onto them). Remaining rings → lines, split per named waterbody (name + WBIC), clipped to the study area. CTEs are `MATERIALIZED` so the big union runs once | Performance: the "water touching in-scope water" test runs against `ST_Subdivide` pieces (≤ 256 vertices) in an indexed table; against whole polygons it took 75 s.. Then smoothing: `ST_SimplifyVW(:shore_simplify_area_m2)` → `ST_Segmentize(:shore_smooth_max_edge_m)` (so Chaikin can't cut long-edge corners far) → `ST_ChaikinSmoothing(:shore_smooth_iterations)` → `ST_SimplifyVW(0.01)` (drops collinear points) |
| `25_narrow_water.sql` | `analysis.water_parts`, `wide_water`, `stream_zone` (water + w/2, buffered as subdivided pieces then unioned), `stream_lines`, `shore_points_2m`, `stream_width`, `stream_steps` | Decides where water is narrow, once, along the county stream centerlines: width every `:narrow_measure_step_m` = distance to the nearest shore on the left + right; rolling median over `:narrow_smoothing_m`; runs under `:narrow_min_run_m` take their neighbor's class; 1 m `stream_steps` carry the result. `wide_water` (morphological opening: buffer −w/2 then +w/2) is the fallback where there's no centerline |
| `30_shore_segments.sql` | `analysis.shore_steps`, `analysis.shore_parcels`, `analysis.shore_segments` | **Sampling:** steps of `:sample_step_m`; each step's midpoint → nearest parcel *polygon* within `:snap_tolerance_m` (none = gap) and a `narrow` flag (the class of the nearest centerline step within `:stream_bank_distance_m`, so banks and centerline agree; else the opening test: no `wide_water` within 0.225 × `narrow_width_m`). Then steps on Lake-type water are forced wide (only flowing water collapses; `analysis.water_type_pieces`, made in `25_narrow_water.sql`, gives the hydtype). Then short runs are absorbed (`:segment_min_run_m`: narrow/wide runs flip; short owned runs take the neighboring owned run's parcel; gaps exempt). Consecutive steps with the same (owner name, parcel's municipality, narrow) collapse into a segment (gaps-and-islands), with exact `ST_LineSubstring` geometry. Runs that wrap around a closed ring's start are merged. |
| `40_classify.sql` | `owner_class`, `owner_label` | First matching rule; gaps → `row` if an OSM street is within `:row_road_distance_m`, else `unknown` |
| `50_municipality.sql` | `muni_id` (gaps), `muni_name`, `muni_type` | Owned segments: the municipality containing the parcel (land side). Gaps: the municipality covering most land within 20 m. Then drops segments whose land-side municipality is outside the study area. |
| `60_access.sql` | `access`, `access_source`, `access_note` | default (class) → osm (area features must cover ≥ half the segment within `:access_evidence_distance_m`; explicit `access=*` tags win; the most open applies) → street_end (`row` segments) → override |
| `70_category.sql` | `category` | the scorecard category from `config/categories.csv`; the only attribute the analysis uses |
| `80_streams.sql` | `analysis.stream_bank_matches`, `stream_segments`; `shore_segments.replaced` | Each narrow centerline step finds the nearest narrow bank segment on each side within `:stream_bank_distance_m` (side = cross product sign), takes the better one by `:stream_category_priority`, and runs collapse into stream segments. Matched banks are marked `replaced`. |

Known rough edges (milestone 2): the Arboretum is two owner strings, so it isn't one
segment; private land inside an OSM nature reserve becomes `open` (by design; fix
exceptions with overrides).

#### `30_export/` → views for tiles (built)

Views, so they're always current with `analysis`. Each view = one tile layer.

| File | View / tile layer | Attributes |
|---|---|---|
| `10_shore.sql` | `shore` (lines) | `water_class` (named / pond), `kind` = bank (not-replaced bank segments) or stream (centerlines; segment_id + 10,000,000), narrow, other_bank_label (stream), segment_id, waterbody, category, owner_class, owner_label, access, access_source, access_note, muni_name, muni_type, length_m |
| `20_parks.sql` | `parks` (polygons) | feature_id, name, category (park / nature_reserve), within 100 m of in-scope shore |
| `30_municipalities.sql` | `municipalities` (polygons), `municipality_labels` (points) | muni_id, name, muni_type. Separate label points so each name is placed once. In `context.pmtiles`. |
| (via `make compare`) | `shore_alt` | same as `shore`, under alternative settings |
| `40_stats.sql` | `stats_municipalities`, `stats_shore` (no geometry → not tiles) | study-area municipalities with population and `shore_bbox` (extent of their shore, 4326); shore length per municipality × waterbody × water_kind (`wide` / `narrow` / `pond`) × category. Narrow water counts once: stream centerlines, plus unmatched narrow banks at half weight. Read by `shore stats`. |

### `site/`: the map and the scorecard (built)

Vite 8 + Solid + TypeScript 6, MapLibre GL 6, `pmtiles`, `@protomaps/basemaps`,
Observable Plot (scorecard chart), TanStack Table v9 (`@tanstack/solid-table`, headless).
Node 24 (`site/.nvmrc`). It reads only `site/public/data/`.

TypeScript is pinned to 6.0.x, the last JavaScript-based release: typescript-eslint
needs the compiler's JS API, which TypeScript 7 (native) doesn't ship yet. Move to 7
when typescript-eslint supports it.

```sh
cd site && nvm use && npm install
npm run dev        # http://localhost:5173/public-private-land/
npm run build      # tsc --noEmit + vite build → site/dist/
npm run format     # prettier --write .
npm run check      # prettier --check, eslint, tsc (also runs in the deploy workflow)
```

**Formatting** is Prettier: 100 columns, no semicolons, single quotes, trailing commas
on multi-line lists only (`trailingComma: "all"`). Arrays print as `[1, 2]`: Prettier has no
array-bracket-spacing option (by design), and we chose Prettier over formatters that
have one (ESLint Stylistic, dprint).

**Linting** is ESLint (flat config, `eslint.config.js`): `@eslint/js` recommended,
typescript-eslint `strictTypeChecked` + `stylisticTypeChecked`, `eslint-plugin-solid`,
`simple-import-sort`, then `eslint-config-prettier` so ESLint never fights Prettier.
House rules on top:

| Rule | Meaning |
|---|---|
| `func-style: declaration` | Named functions are `function f() {}`; inline callbacks may be arrows |
| `explicit-function-return-type` | Every named function states its return type (components: `JSX.Element`) |
| `no-explicit-any`, `no-non-null-assertion` (strict) | No `any`, no `x!`. Prefer total lookups (`Record<Union, …>`) and explicit checks |
| `consistent-type-imports` | `import { type X }` for type-only imports |
| `simple-import-sort` | Sorted, grouped imports/exports (auto-fixed) |
| `naming-convention` | camelCase; PascalCase types and components; UPPER_CASE module constants; property names exempt (snake_case tile attributes, MapLibre style keys) |
| `eqeqeq`, `curly: all`, `no-console` (warn/error allowed) | |

`npx eslint . --fix` fixes import order, type imports and some style rules.

| File | Role |
|---|---|
| `src/App.tsx` | Top bar (Map / Scorecard tabs, km / mi switch) and the active view. The map stays mounted while hidden, so it's never rebuilt |
| `src/lib/contract.ts` | Frontend half of the data contract: tile layer names, `ShoreProps`, `Stats` (stats.json), class/access/category unions |
| `src/lib/categories.ts` | Category labels, descriptions, which count as public access by default |
| `src/lib/units.ts` | Display units: data is meters; format as km/mi (long) or m/ft (short) |
| `src/state/store.ts` | Solid signals: `view`, `units`, `colorBy` (category/access), `showAlt`, `hasAlt`, `showMunis`, `shadeMunis`, `selected`, `focusMuni`, `stats`, `measure`, `metric`; `scores` (memo shared by the scorecard and the map shading); `loadStats` |
| `src/map/MapView.tsx` | Creates the map **once**. Registers the `pmtiles://` protocol; basemap from `@protomaps/basemaps` (light/dark picked at load from the OS setting); sources: basemap, `shore`, `context`; layers: municipality shading (fill by the current measure, hidden by default), parks (dashed outline), municipal boundaries (dashed, hidden by default), focused-municipality outline, shore casing + line + invisible wide hit line, selection outline, municipal labels. Signals update paint/visibility/filter in place. Focusing a municipality fades other shore (`line-opacity`), limits clicks to its shore, and fits the map to its `shore_bbox`. |
| `src/map/colors.ts` | Colors and MapLibre `match` expressions. Categories fold into 4 groups (municipal access, other-provider access, no access, unknown; a map is an all-pairs view, where only 3 hues stay CVD-safe). Access uses the status palette with icons. Shading uses the sequential blue ramp in 5 classes. Validated with the dataviz validator. |
| `src/components/Panel.tsx` | Map side panel: title, color-by toggle, legend, municipality picker (with its score for the current measure), boundary and shading toggles, tolerance toggle (only if `shore_alt` exists), selected-segment details, disclaimer |
| `src/scorecard/measures.ts` | `Measure` (numerator categories ⊆ denominator categories, water types: default wide + narrow, ponds opt-in), preset `REPORTS`, `computeScores` / `totalScore` over stats.json rows. `unknown` is never counted (excluded until cleaned up) but reported per municipality |
| `src/scorecard/Scorecard.tsx` | Report picker (a measure matching no preset shows as Custom), water filter, shore-floor slider (`minShoreM`, default 1 km; also filters the map shading), category builder (Counts / Out of checkboxes), study-area summary, rank-by switch, chart, table |
| `src/scorecard/Chart.tsx` | Observable Plot ranked bars for the current metric (share, distance, per 1,000 residents); hover tip; redraws on resize |
| `src/scorecard/ScoreTable.tsx` | TanStack Table: municipality names jump to the map focused on them; sortable columns (share, counted, out of, per 1,000 residents, population, unknown excluded) |
| `vite.config.ts` | `base: '/public-private-land/'`; `worker.format: 'es'` |

**MapLibre worker gotcha:** MapLibre 6 loads its Web Worker from a file next to its own
module, which breaks once Vite moves the module (pre-bundling in dev, bundling in
build). `MapView.tsx` imports the worker with `?worker&url` and passes it to
`setWorkerUrl()`.

### `.github/workflows/deploy.yml`

`npm ci` → `npm run check` → `npm run build` → `upload-pages-artifact` → `deploy-pages`. It's **manual only**
(`workflow_dispatch`) while `site/public/data/` is gitignored; restore the `push`
trigger when the data is committed. The repo's Pages source must be set to
"GitHub Actions".

### `pipeline/adhoc/`: one-off analysis (not the pipeline)

Queries and exports used to make decisions, kept so they can be rerun. Make never runs
them and they never feed the site. Outputs go to `data/build/review/` (gitignored) and
may contain owner names and billing addresses, so they stay local. Example:
`pipeline/adhoc/review_exports/export.sh` writes review GeoJSON for QGIS.

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
