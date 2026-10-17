# AGENTS.md

Guidance for AI coding agents (and humans) working in this repo.

## Project

An interactive map of **shore access in Dane County, Wisconsin**: every lake and river
shoreline, split into segments, classified by **who owns the adjacent land** (public
vs. private, with finer-grained classes) and **whether the public can actually get to
the water there**, and attributed to the **municipality** it falls in. Alongside the
map: stats such as linear shore length per municipality per ownership class and per
access status.

Ownership and access are **separate attributes**. Public ownership doesn't imply access
(a water utility parcel, for example), and private ownership doesn't rule it out (a
land-trust preserve).

Two halves:

1. **Data pipeline** (local, expensive, run by hand): raw public datasets go in, and
   map tiles plus stats come out.
2. **Static site** (GitHub Pages, client-only): renders the committed outputs.

**Status:** Milestone 2 (Lake Wingra thin slice) in progress. Built: pipeline
container, `shore` CLI (`load`, `sql`), Makefile with stamps, SQL through
`20_analysis` (classified Wingra segments), ownership/access config CSVs, unit tests.
Export → `shore.pmtiles` and the basemap extract work. Next: site.
`site/public/data/` is temporarily gitignored until the owner approves the output. Milestone 1 recon findings live in
`config/sources.toml` notes and the Decisions log.

**Code architecture:** see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). It covers what
each piece does and where to change things. Keep it current as code changes.

Deferred:
- [ ] Snap tolerance: 5 m vs ~10–15 m (small inlets at Wingra are 6–13 m off). Decide
      in milestone 2 by comparing segment outputs at both tolerances.

### Spirit of the project

This is a **for-fun learning project**. The owner is interested in GIS.

- Prefer **standard, industry-typical GIS tools and practices** over clever shortcuts.
  Learning the "real" way is the point.
- Overengineering is acceptable when it's interesting. Ceremony that isn't fun is not.
- When introducing a GIS concept (CRS choice, topology, snapping tolerance, etc.),
  briefly explain *why*.
- Testing: **some, not a lot.** See [Testing](#testing).

## Tech stack

| Layer | Choice |
|---|---|
| Pipeline language | Python 3.12, managed with **uv** |
| Lint/format | **ruff** |
| Tests | **pytest** (light) |
| Spatial database | **PostGIS** (Docker) |
| Transforms | **Plain numbered SQL files** run via `psql` |
| Orchestration | **Makefile** |
| Geo CLI tools | GDAL/OGR (`ogr2ogr`), `osmium-tool`, **tippecanoe**, `pmtiles` CLI |
| Python geo libs | GeoPandas, Shapely 2, pyogrio, pyproj, psycopg 3 (use when SQL is awkward) |
| Reproducibility | **Docker Compose** for everything: PostGIS + a pipeline container with GDAL/tippecanoe/uv pinned |
| Tile format | **PMTiles** (single-file vector tiles via HTTP range requests, no tile server) |
| Frontend | **Vite + Solid + TypeScript** |
| Map library | **MapLibre GL JS** + `pmtiles` protocol |
| Basemap | **Protomaps** basemap PMTiles extract clipped to Dane County (streets with names for orientation; swappable later) |
| Hosting | **GitHub Pages**, deployed by GitHub Actions |

## Data sources

All four are used. Exact download URLs, layer names, and field names **must be verified
when implementing**. Record them in `config/sources.toml` together with
the license/attribution and retrieval date, rather than hardcoding them in scripts.

| Source | Used for |
|---|---|
| **Dane County parcels**: Dane County Land Information Office, or the Wisconsin Statewide Parcel Map (SCO/LTSB "V-series") | Parcel polygons with **owner names** (e.g. `OWNERNME1`). This is the primary signal for public vs. private. |
| **Dane County hydrography**: Lakes and Ponds polygons, Rivers and Streams lines (~1:2,400, county LIO) | **Shoreline geometry.** Aligns with parcels to a few meters. Delivered in EPSG:7599 (feet) and reprojected to 3071 |
| **WI DNR 24K Hydrography** | Waterbody **identity** (WBIC, official names) via spatial join. Its geometry is 12–25 m+ off the parcels, so it is not used for shape |
| **OpenStreetMap**: Geofabrik Wisconsin extract, filtered with `osmium` | Parks, boat launches (`leisure=slipway`), piers, beaches, access tags; cross-checking parcel results |
| **Municipal boundaries**: LTSB or Dane County | Cities, villages, and towns, used to attribute shore segments to a municipality |

Study area: **all of Dane County**. Use the county boundary as the clip mask.

## Architecture

```
download ──► load ──► transform (SQL) ──► export ──► tiles ──► site
 (files)   (ogr2ogr   (raw → staging     (GeoJSON/   (tippecanoe  (Vite build,
           → PostGIS)  → analysis)        stats)      → PMTiles)   GH Pages)
```

The pipeline is a hybrid of files and database: raw downloads are **files**, the
analysis happens in **PostGIS SQL**, and products are exported back out to **files**.

### Repo layout

```
.
├── AGENTS.md                     # this file (CLAUDE.md just imports it)
├── README.md                     # human-facing overview + quickstart
├── docs/ARCHITECTURE.md          # how the code pieces fit together (humans + agents)
├── Makefile                      # single entry point for the pipeline
├── docker-compose.yml            # services: db (PostGIS), pipeline (tools)
├── .env.example                  # PG* connection vars; copy to .env (gitignored)
│
├── config/                       # ALL tunable knobs live here, shared by SQL + Python
│   ├── pipeline.toml             # study area, analysis CRS, snap tolerance, zoom levels
│   ├── sources.toml              # dataset URLs, layer names, licenses, retrieval dates
│   ├── ownership_rules.csv       # ordered regex: owner name → class + display label
│   ├── access_defaults.csv       # ownership class → default access status
│   └── access_overrides.csv      # hand-curated access facts (id/geometry → status, note)
│
├── pipeline/                     # everything that produces data
│   ├── Dockerfile                # GDAL base + tippecanoe + osmium + pmtiles + uv
│   ├── pyproject.toml            # uv project; console script `shore`
│   ├── uv.lock
│   ├── src/shore/                # src-layout Python package
│   │   ├── cli.py                # Typer app: `shore <command>`, called by Make
│   │   ├── config.py             # loads config/*.toml into typed objects
│   │   ├── download.py           # fetch sources.toml entries → data/raw/
│   │   ├── load.py               # ogr2ogr / osmium wrappers → raw schema
│   │   ├── sqlrun.py             # runs sql/<stage>/*.sql in order w/ psql vars
│   │   ├── export.py             # export views → GeoJSON(Seq) for tippecanoe
│   │   └── stats.py              # analysis tables → stats.json
│   ├── sql/                      # one directory per schema stage
│   │   ├── 00_init/              # extensions, schemas, helper functions
│   │   ├── 10_staging/           # clean, reproject, ST_MakeValid, index
│   │   │   ├── 10_municipalities.sql
│   │   │   ├── 20_county_boundary.sql  # union of municipalities
│   │   │   ├── 30_hydro.sql
│   │   │   ├── 40_parcels.sql
│   │   │   └── 50_osm.sql
│   │   ├── 20_analysis/          # shoreline → segments → classes → municipalities
│   │   │   ├── 10_ownership_rules.sql
│   │   │   ├── 20_shoreline.sql
│   │   │   ├── 30_shore_segments.sql
│   │   │   ├── 40_classify.sql
│   │   │   ├── 50_municipality.sql
│   │   │   └── 60_access.sql     # defaults → OSM evidence → street ends → overrides
│   │   └── 30_export/            # views shaped for tiles + stats
│   └── tests/
│       ├── unit/                 # pure Python, no DB (classifier rules); runs in CI
│       └── data/                 # pytest against PostGIS; local only
│
├── data/                         # GITIGNORED, regenerable
│   ├── raw/<source>/             # untouched downloads, one dir per source
│   └── build/
│       ├── .stamps/              # Make freshness markers for DB steps
│       └── export/               # intermediate GeoJSON before tippecanoe
│
├── site/                         # Vite + Solid + TypeScript
│   ├── package.json
│   ├── vite.config.ts            # base: '/public-private-land/'
│   ├── index.html
│   ├── src/
│   │   ├── index.tsx
│   │   ├── App.tsx
│   │   ├── map/                  # MapLibre setup, pmtiles protocol, layers, styles
│   │   ├── components/           # Solid UI: legend, public-definition picker, stats panel, popup
│   │   ├── state/                # signals/stores (which classes count as public, etc.)
│   │   └── lib/                  # shared types (ownership classes, stats.json schema)
│   └── public/data/              # COMMITTED pipeline outputs
│       ├── shore.pmtiles
│       ├── basemap.pmtiles
│       └── stats.json
│
└── .github/workflows/
    ├── deploy.yml                # build site/ → GitHub Pages
    └── ci.yml                    # ruff + unit tests (optional)
```

Structural rules:

- **`config/` is the single source of truth** for tunables. SQL never hardcodes a CRS,
  tolerance, or bbox. `shore sql run` passes values from `pipeline.toml` as psql
  variables (`-v crs=3071`), and SQL refers to them as `:crs` / `:'name'`.
- **SQL directories mirror the schemas.** `sql/10_staging/` writes only to `staging`,
  `20_analysis/` only to `analysis`, and so on. Numeric prefixes on directories and
  files set run order, with gaps of 10 so new steps can be inserted.
- **Python is glue, not analysis.** Geometry logic belongs in SQL. Python handles
  downloading, loading, running SQL, exporting, and writing stats. Reach for GeoPandas
  only when SQL is genuinely awkward, and say why in a comment.
- **The pipeline writes into `site/public/data/` and nowhere else that is committed.**
- **`site/src/lib/` holds the frontend side of the data contract.** If the stats.json
  shape or the tile layer/attribute names change, update the export SQL, `stats.py`,
  and these types together.

### Makefile

- Targets: `db-up`, `db-down`, `db-reset`, `psql`, `download`, `load`, `staging`,
  `analysis`, `export`, `tiles`, `basemap`, `stats`, `test`, `all`.
- Recipes are thin, typically `$(RUN) shore <cmd>`, where `RUN` is
  `docker compose run --rm pipeline`, so host tool versions don't matter.
- Make can't see inside PostGIS, so each DB stage writes a stamp file to
  `data/build/.stamps/<stage>`. That stamp depends on the stage's SQL files, on
  `config/`, and on the previous stamp, so editing one SQL file reruns only that stage
  and the stages after it.

### PostGIS conventions

- Schemas: `raw` (as loaded by `ogr2ogr`), `staging` (cleaned, reprojected, valid
  geometries), `analysis` (shore segments and classification), `export` (views shaped
  for tippecanoe/stats).
- SQL files are **idempotent** (`DROP ... IF EXISTS` / `CREATE OR REPLACE`) and run in
  filename order. Re-running a file must be safe.
- **Analysis CRS:** a projected CRS in **meters**. Default to **EPSG:3071** (NAD83(HARN) /
  Wisconsin Transverse Mercator), the DNR's standard, set in `config/pipeline.toml`.
  Verify the choice, or switch to a WISCRS Dane County CRS if accuracy demands it.
  Store and compute in this CRS, and reproject to EPSG:4326 only at export.
- Run `ST_MakeValid` on load into staging. Put GiST indexes on every geometry column used
  in joins.

### Core analysis method: parcel-intersected shoreline

1. **Shoreline:** take county hydro water polygons (lakes, wide rivers) → `ST_Boundary`
   → lines. **Drop seams between water polygons** (e.g. where Lake Wingra meets the
   Wingra Creek polygon). Those edges are water touching water, not shore. **Scope:** lakes above a minimum area plus rivers and streams that the county maps
   as **polygons** (e.g. the Yahara, Starkweather Creek, most of Black Earth Creek).
   Stormwater ponds, unnamed ditches, and wetland edges are excluded. Thresholds live in
   `config/pipeline.toml`. Narrow streams that exist only as lines (Rivers and Streams
   layer) are **out of scope for now**; see the Decisions log.
2. **Split by parcel:** parcel edges rarely coincide exactly with hydro shorelines.
   Assign shoreline to the adjacent parcel(s) within a **snapping tolerance** (start
   around 10–20 m and tune it). Split the shoreline wherever the adjacent parcel changes.
3. **Gaps:** shoreline with no adjacent parcel within tolerance is usually road
   right-of-way or unparceled land. Classify it as `row` when it touches a road (OSM or
   parcel ROW), otherwise `unknown`.
   Note: in Dane County data, parcel edges often sit a few meters **inland** of the
   waterline, leaving a thin unparceled strip (seen along Vilas Park at Lake Wingra).
   The snap tolerance must bridge that strip, so it is never classified as a gap.
   **Merge** adjacent segments that share the same owner and class. Large holdings are
   split into several parcels along survey (PLSS) lines, e.g. the UW Arboretum, and
   those splits shouldn't fragment the shoreline.
4. **Classify:** map each owner name to an ownership class using
   `config/ownership_rules.csv` (ordered regex patterns loaded into a table, so the rules
   are data, not code).
   The parcel `AUXCLASS` exemption codes (X1 federal, X2 state, X3 county, X4 other
   exempt) are a **secondary signal** for flagging disagreements and filling gaps. They
   are applied too inconsistently to drive classification on their own.
5. **Municipality:** attach the municipality name and type (city/village/town) from
   the **land side**: the municipality the adjacent parcel lies in. Municipal polygons
   include lake water, so testing the shoreline itself mislabels shore. Gap segments
   (no parcel) use a point just inland of the segment.
6. **Access:** assign each segment an access status. See [Access model](#access-model).
7. **Stats:** sum `ST_Length` per municipality × ownership class and per municipality ×
   access status, in meters and miles.

Shore length depends on the scale of the source data (the coastline paradox). All
lengths come from the county's ~1:2,400 hydrography, and the site says so.

### Ownership classes

Multi-class, not binary. The frontend lets users choose which classes count as
"public".

Starting set: `federal`, `state` (including WI DNR), `county`, `municipal`,
`university`, `school_district`, `utility`, `other_public`, `private`, `row` (road
right-of-way), `unknown`.

**Edge cases are decided per case as they're found** during data recon, as real owner
names turn up (land trusts, HOA/condo common land, churches, private colleges, sewerage
districts, etc.). Add classes when they're needed, and record each decision in the
[Decisions log](#decisions-log).

**Owner display labels:** each rule in `config/ownership_rules.csv` also maps to a broad,
human-friendly **label** shown on the map, such as `State`, `County`, `UW–Madison`,
`Edgewood College`, `Church`, or a municipality name like `City of Madison` (regex
capture groups are allowed). Private individuals get the label `Private`.

**Privacy:** raw owner names stay in the local database for auditing and are **never
exported** to tiles or stats. Only class and label ship to the site.

### Access model

Each segment gets an `access` status alongside its ownership class:

- `open`: the public can legally reach the water here (park, boat launch, public
  street end, open preserve)
- `restricted`: public or institutional land with limited or permitted access (hours,
  fees, members/students only, or closed facilities)
- `none`: no public access from land
- `unknown`: not yet determined

Each segment also carries `access_source`, which records which layer set the status:

1. **Default from ownership class** (`config/access_defaults.csv`), e.g. `municipal` →
   `unknown` and `private` → `none`.
2. **OSM evidence** overrides the default: `leisure=park`, `leisure=slipway`,
   `leisure=beach_resort`, `natural=beach`, and `access=*` tags on adjacent features.
3. **Street ends:** public road right-of-way that meets the water counts as `open`
   (Wisconsin generally treats these as public access; note that some are posted or
   vacated).
4. **Manual overrides** (`config/access_overrides.csv`) always win. Each row has a note
   explaining the reason.

**Public trust doctrine:** in Wisconsin, the beds of navigable waters are held in trust
for the public. The site needs a short methodology note explaining that "no access from
land" ≠ "can't be on the water", plus a **not-legal-advice** disclaimer.

### Outputs (committed)

Written to `site/public/data/` and committed to git:

- `shore.pmtiles`: shore segments (class, owner label, access, access source,
  municipality, length) and parks. **No raw owner names.** Access evidence (boat
  launches, beaches, etc.) feeds the access attribute but is not exported as map features.
- `basemap.pmtiles`: Protomaps extract for Dane County
- `stats.json`: per-municipality × class and × access lengths, plus totals and dataset metadata
  (source dates)

Size budget: GitHub rejects files **> 100 MB** and warns at 50 MB. Keep each output
under ~50 MB by tuning tippecanoe zoom levels and attribute dropping. If that becomes
impossible, move the files to Git LFS (with `lfs: true` on checkout in CI) or to a
GitHub Release asset.

## Frontend

- Vite + Solid + TypeScript, `maplibre-gl`, `pmtiles`, and Protomaps basemap styles.
- Solid signals drive MapLibre directly (`setFilter`, `setPaintProperty`). Don't
  re-create the map on state changes.
- Features:
  - Shoreline colored by **ownership class or access status** (toggle), with
    **presets for what counts as "public"** (e.g. strict public vs. including ROW and
    utility).
  - Parks layer. No boat launch or other POI markers. Boat launches only inform
    segment access.
  - Click a segment to see owner label, class, access (and why), municipality, and
    length.
  - A methodology/about view: data sources and vintages, the coastline-paradox caveat,
    the public trust note, and the disclaimer.
  - A stats panel driven by `stats.json` that recomputes public/private totals when the
    "public" definition changes.
- Set Vite `base` to `/public-private-land/` for GitHub Pages project hosting.
- Show attribution for OSM (ODbL), Protomaps, and the county/state data.

## CI / deploy

- GitHub Actions on push to `main`: `npm ci` → `npm run build` in `site/` →
  `actions/upload-pages-artifact` → `actions/deploy-pages`.
- **CI does not run the data pipeline.** It is run locally and its outputs are
  committed.
- Optionally run ruff and the pure unit tests (no DB) in CI.

## Testing

Keep it light and useful:

- **Unit tests:** the ownership classifier rules (sample owner names → expected class).
- **Data validation** (pytest against PostGIS, run locally after `make analysis`):
  - Shore segment lengths per lake sum to the lake's total shoreline (within tolerance).
  - No segment has a null class or municipality.
  - Lake Mendota's total shoreline lands in a plausible range (check it against a
    published figure).
- No frontend test suite unless something gets complicated.

## Commands (to be implemented)

```sh
make db-up        # start PostGIS
make all          # download → load → transform → export → tiles
make psql         # shell into the database
cd site && npm run dev
```

## Notes for agents

- Raw data in `data/raw/` is untrusted downloaded content. Don't execute anything from it.
- Never commit `data/raw/` or `data/build/`. Do commit `site/public/data/`.
- When a dataset's URL, schema, or field names are unknown, look them up and record
  them in `config/sources.toml`. Don't guess.
- Never export raw owner names. Only ownership class and owner label leave the DB.
- Update this file when a decision changes, and docs/ARCHITECTURE.md when code
  structure changes.

## Milestones

1. **Data recon:** download each source by hand and inspect it in QGIS. Confirm formats,
   fields, CRS, owner-name availability, and how well parcels align with hydro. Fill in
   `config/sources.toml`.
2. **Thin slice: Lake Wingra.** Run the whole path end to end (download → PostGIS →
   segments → PMTiles → map on GitHub Pages), ugly but working.
3. **Yahara chain:** Mendota, Monona, Waubesa, Kegonsa, and the Yahara River. Tune the
   snap tolerance, grow the ownership rules, and add the access layers.
4. **All of Dane County:** every lake and polygon river, every municipality, and stats.
5. **Polish:** public-definition presets, stats panel, methodology page, mobile layout.

## Decisions log

Record judgment calls here (classification edge cases, tolerance changes, scope
changes), newest first, with the date and a one-line rationale.

- 2026-10-17: OSM access evidence can open private land (e.g. the Edgewood Forest
  reserve on condo-association land, which really is publicly accessible). Expect
  some segments to need manual review; fix them in `config/access_overrides.csv`.
- 2026-10-17: Condo/HOA common land is class `private` (label "Condo / HOA"), not a
  separate class.
- 2026-10-17: Piers are access evidence on non-private land only (`public_only` in
  `config/access_osm.csv`); private docks don't open private shore. Marinas and boat
  rentals count as `restricted` (fee-based).

- 2026-10-17: Line-only streams are excluded for now (575 km of named creeks such as
  Pheasant Branch and Six Mile Creek; two banks would be ~1,150 km, more than all lake
  shore). Shoreline comes only from water polygons. Revisit later.
- 2026-10-17: Snap tolerance stays at 5 m for now; compare outputs at 5 m vs 10–15 m
  in milestone 2 before deciding.

- 2026-10-17: Shore segments get their municipality from the land side (the adjacent
  parcel), not from the line. Municipal polygons include lake water, so the line itself
  mislabels ~17% of Mendota's shore (e.g. Maple Bluff shore as City of Madison).

- 2026-10-17: Dropped the DNR boat access sites dataset; not needed.
- 2026-10-16: Shoreline geometry comes from Dane County hydrography, not DNR 24K. 24K
  was 12–25 m+ off the parcels; the county layer is p50 1.6 m (85% within 5 m) at
  Wingra. Snap tolerance starts at 5 m. DNR 24K is kept for WBIC and names.
- 2026-10-16: Lake Wingra recon: lakes are unparceled; road ROW is unparceled (gaps
  between parcels, not ROW parcels); parcel edges sit a few meters inland of the
  waterline. Merge same-owner adjacent segments because of PLSS-line parcel splits.
- 2026-10-16: Parcels come from SCO V12 (file geodatabase, EPSG:3071). Dane does not
  redact owner names. Owner-name rules are primary and AUXCLASS is secondary, because
  e.g. only ~5% of City of Madison parcels carry X4.
- 2026-10-16: Ownership and access are modeled as separate attributes, with access
  included from v1.
- 2026-10-16: Shore scope is lakes above a size threshold plus named rivers and
  streams.
- 2026-10-16: Map labels are broad owner categories from config. Raw names are never
  published.
