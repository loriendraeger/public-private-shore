# AGENTS.md

Guidance for AI coding agents (and humans) working in this repo.

## Project

**Goal: compare how well municipalities in central Dane County, Wisconsin provide public
access to their water.** The product is a **municipal scorecard**: for each city, village
and town, how much of its shoreline the public can reach from land. It is not a guide to
individual access spots.

Under the scorecard: every in-scope shoreline, split into segments, classified by **who
owns the adjacent land** (public vs. private, with finer-grained classes) and **whether
the public can actually get to the water there**, and attributed to the **municipality**
whose land it borders. The segment map is the evidence behind each municipality's score.

Scorecard measures (decided 2026-10-17), each as **% of the municipality's shoreline and
absolute km**:
- **Public access available**: shore with public access, whoever provides it (state,
  county, UW, land trusts, the municipality, street ends).
- **Provided by the municipality**: the part it provides itself (its own land and street
  ends).

Because scores compare municipalities, uncertainty matters: no shore is left `unknown`
(decided by rules and review), and users can leave out municipalities with little shore.

Ownership and access are **separate attributes**. Public ownership doesn't imply access
(a water utility parcel, for example), and private ownership doesn't rule it out (a
land-trust preserve).

Two halves:

1. **Data pipeline** (local, expensive, run by hand): raw public datasets go in, and
   map tiles plus stats come out.
2. **Static site** (GitHub Pages, client-only): renders the committed outputs.

**Status (2026-10-19):** milestones 1–6 done; 7 (ship) and 8 (explain and polish) partly
done. See [Milestones](#milestones). The full pipeline (load → staging → analysis →
export → tiles) and the site run locally. `site/public/data/` is committed, and the
deploy workflow runs on every push to `main` (GitHub Pages, source: GitHub Actions); the
first deploy is still to be checked.

**Code architecture:** see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). It covers what
each piece does and where to change things. Keep it current as code changes.


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
| Frontend lint/format | **ESLint** (typescript-eslint, eslint-plugin-solid) + **Prettier** |
| Map library | **MapLibre GL JS** + `pmtiles` protocol |
| Scorecard charts | **Observable Plot** |
| Scorecard tables | **TanStack Table** (`@tanstack/solid-table`, headless) |
| Scorecard measures | Plain TypeScript over a tidy `stats.json` (no dataframe/SQL engine) |
| Basemap | **Protomaps** basemap PMTiles extract clipped to Dane County (streets with names for orientation; swappable later) |
| Hosting | **GitHub Pages**, deployed by GitHub Actions |

## Data sources

All are used. Exact download URLs, layer names, and field names **must be verified
when implementing**. Record them in `config/sources.toml` together with
the license/attribution and retrieval date, rather than hardcoding them in scripts.

| Source | Used for |
|---|---|
| **Dane County parcels**: Dane County Land Information Office, or the Wisconsin Statewide Parcel Map (SCO/LTSB "V-series") | Parcel polygons with **owner names** (e.g. `OWNERNME1`). This is the primary signal for public vs. private. |
| **Dane County hydrography**: Lakes and Ponds polygons, Rivers and Streams lines (~1:2,400, county LIO) | **Shoreline geometry.** Aligns with parcels to a few meters. Delivered in EPSG:7599 (feet) and reprojected to 3071 |
| **WI DNR 24K Hydrography** | Waterbody **identity** (WBIC, official names) via spatial join. Its geometry is 12–25 m+ off the parcels, so it is not used for shape |
| **OpenStreetMap**: Geofabrik Wisconsin extract, filtered with `osmium` | Parks, boat launches (`leisure=slipway`), piers, beaches, access tags; cross-checking parcel results |
| **Municipal boundaries**: LTSB or Dane County | Cities, villages, and towns, used to attribute shore segments to a municipality |
| **Population**: WI DOA Demographic Services Center, final municipal estimates (1/1/2026) | Per-capita scorecard measures |

Study area: **30 municipalities in central Dane County** (the Yahara lakes region plus
Stoughton and the Village of Oregon), listed in `config/pipeline.toml` `[study_area]`.
Shore is in scope when its land side lies in one of them. Staging stays county-wide.

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
├── LICENSE                       # code: GPL-3.0-or-later
├── LICENSE-DOCS                  # docs + methodology: CC BY-SA 4.0
├── LICENSE-DATA                  # outputs + config/*.csv: ODbL 1.0, upstream attributions
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
│   ├── adhoc/                    # one-off review queries/exports; NOT run by make
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
│   ├── vite.config.ts            # base: '/public-private-shore/'
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
│       ├── context.pmtiles
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
   Assign shoreline to the parcel **behind** it within a **snapping tolerance** (15 m):
   short inland rays (transects) from each shore step, not the nearest parcel in any
   direction, so lots beside a street end can't claim it. A parcel that extends into
   the water (a private pond) owns its shore. Split the shoreline wherever the
   adjacent parcel changes.
3. **Gaps:** shoreline with no adjacent parcel within tolerance is usually road
   right-of-way or unparceled land. Classify it as `row` when it touches a road (OSM or
   parcel ROW), otherwise `unknown`.
   Note: in Dane County data, parcel edges often sit a few meters **inland** of the
   waterline, leaving a thin unparceled strip (seen along Vilas Park at Lake Wingra).
   The snap tolerance must bridge that strip, so it is never classified as a gap.
   **Narrow water** (under `narrow_width_m`, measured locally by morphological opening)
   is represented once, by the county stream centerline, which takes the better of its
   two banks; see `25_narrow_water.sql` and `80_streams.sql`.
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

### Scorecard categories

Ownership classes and access are inputs. **The analysis (scorecard, stats) uses one
category per segment**, derived from both after access is assigned. Owner labels and
access reasons are map-only detail. (Decided 2026-10-17; mapping in `config/categories.csv`,
applied by `20_analysis/70_category.sql`.)

| Category | Meaning | Map shows | Public access? |
|---|---|---|---|
| `municipal` | municipality-owned and accessible, plus street ends | owner label (`City of Madison`, `Street end`) | yes; the municipality's own |
| `county` | county-owned and accessible | `Dane County` | yes |
| `state_federal` | state or federal and accessible (DNR, WisDOT, UW is separate) | owner label | yes (toggle) |
| `university` | UW–Madison and accessible | `UW–Madison` | yes (toggle) |
| `land_trust` | conservation land trust preserve, accessible | `Land trust` | yes (toggle) |
| `other_public` | other public bodies (sewerage, lake districts) and accessible | owner label | yes (toggle) |
| `private_public_access` | privately owned with public access (e.g. Edgewood condos) | owner label | yes (toggle) |
| `public_no_access` | publicly owned, no public access | owner label + reason (barrier, no land route, facility, institutional grounds) | no |
| `private` | privately owned, no public access | `Private`, `Condo / HOA`, `Church` (no individual owners) | no |
| `unknown` | owner or access not determined (pipeline fallback; none left, not shown on the site) | — | — |

Which categories count as public access is a site setting (presets plus toggles).

### Access model

Each segment gets an `access` status alongside its ownership class:

- `open`: the public can legally reach the water here (park, boat launch, public
  street end, open preserve). Fees open to anyone still count as `open`.
- `none`: no public access from land, including members-, students- or residents-only
  areas and closed facilities
- `unknown`: not yet determined

Each segment also carries `access_source`, which records which layer set the status:

1. **Default from ownership class** (`config/access_defaults.csv`), e.g. `municipal` →
   `unknown` and `private` → `none`.
2. **OSM evidence** overrides the default: `leisure=park`, `leisure=slipway`,
   `leisure=beach_resort`, `natural=beach`, and `access=*` tags on adjacent features.
   On private land only named features (or `access=yes`) count.
3. **Shore paths:** public land still `unknown` is `open` when a public footway or
   cycleway reaches it without crossing railway tracks.
4. **Street ends:** public road right-of-way that meets the water counts as `open`
   (Wisconsin generally treats these as public access; note that some are posted or
   vacated). Highway right-of-way (numbered routes: OSM `ref`) is public, no access.
5. **Barriers:** open or unknown shore cut off from the land by a railway becomes `none`.
3b. **Owner names:** `config/access_owner_rules.csv` (DNR, parks → open; prisons, golf,
   stormwater, highways → none).
3c. **Next to a park:** public land within 50 m of an OSM park or nature area → open.
6. **Short gaps:** a short unknown between two matching, known segments takes theirs,
   access source included (it isn't a source of its own).
6b. **No evidence:** anything still unknown → none (nothing public reaches it).
7. **Manual overrides** (`config/access_overrides.csv`) always win. Each row has a note
   explaining the reason. Rows are keyed by parcel (`stateid`), so they survive
   resegmentation; they can also set the owner class and label.

Each layer records the kind of evidence and its name (park, trail, street).
`config/access_display.csv` turns them into the text the map shows: an access label
("Open to the public", "None" for private shore) and a reason ("Park: Olin Park",
"Public path").

**Public trust doctrine:** in Wisconsin, the beds of navigable waters are held in trust
for the public. The site needs a short methodology note explaining that "no access from
land" ≠ "can't be on the water", plus a **not-legal-advice** disclaimer.

### Outputs (committed)

Written to `site/public/data/` and committed to git:

- `shore.pmtiles`: shore segments (class, owner label, access, access source,
  municipality, length) and parks. **No raw owner names.** Access evidence (boat
  launches, beaches, etc.) feeds the access attribute but is not exported as map features.
- `context.pmtiles`: county-wide reference layers: municipal boundary polygons
  (muni name and type, used for shading by the selected measure) and one label point
  per municipality. Layer-to-file assignment is `[tiles.files]` in `pipeline.toml`.
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
  - Routing with `@solidjs/router`, **hash URLs** (`#/map`, `#/scorecard`, `#/about`; GitHub Pages
    has no SPA fallback). Map params: `bbox=w,s,e,n`, `municipality=<slug>`, `seg=<id>`
    (temporary, for review lists), `color=access`. Scorecard params:
    `report=<id>` or a custom `count=…&of=…&water=…`, `rank`, `min_shore` (m), `sort`.
  - A methodology/about view: data sources and vintages, the coastline-paradox caveat,
    the public trust note, and the disclaimer.
  - A stats panel driven by `stats.json` that recomputes public/private totals when the
    "public" definition changes.
- Set Vite `base` to `/public-private-shore/` for GitHub Pages project hosting.
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
- The site needs Node 24 (`site/.nvmrc`): run `nvm use` first. Under the default Node 20,
  ESLint's formatter and `vite build` crash.
- Checking the site in a headless browser: `puppeteer-core` (installed in a scratch
  directory, not the repo) driving the system Chrome. The map needs WebGL2, which
  headless Chrome on macOS only has with
  `args: ['--use-angle=metal', '--enable-gpu', '--ignore-gpu-blocklist']`. The
  SwiftShader flags (`--use-angle=swiftshader`, `--enable-unsafe-swiftshader`) give no
  WebGL2 and stalled the page. The scorecard needs no flags.

## Milestones

Rewritten 2026-10-17 around the municipal scorecard goal; 4 and 5 swapped the same day
(fix data quality before merging).

1. ✅ **Data recon.** Every source inspected; findings in `config/sources.toml`.
2. ✅ **Thin slice: Lake Wingra.** Download → PostGIS → segments → PMTiles → map, working
   locally. (Deploying moved to milestone 7.)
3. ✅ **Study-area analysis.** 30 municipalities, named water, islands excluded unless
   bridged, first pass of ownership rules on real owner names.
4. ✅ **Categories + access quality.** Scorecard categories in place, `restricted`
   dropped, and access trustworthy enough to rank municipalities (2026-10-18):
   - **Barriers:** railways (local test: tracks within 10 m, or every public way across
     them), rail causeways dropped like islands, highway right-of-way is no access.
     Reviewed on the map.
   - **Private land with public access:** named OSM parks/reserves on private land plus
     overrides (Edgewood). Reviewed and confirmed.
   - **Unknowns:** 83 km -> 0. Hook Lake's bog edges excluded; the rest decided by rules
     (paths, owner names, next to a park, no evidence) and parcel-keyed overrides; the
     25 least-certain decisions spot-checked.
   - **Snap tolerance:** 15 m was fine; the nearest-parcel method wasn't. Shore now
     takes the parcel behind it (inland rays), which recovered the street ends.
   - Later (not blocking): land-side reachability (barriers beyond railways: fences,
     motorways); more evidence for private land with public access (DNR stewardship,
     Managed Forest Law "open" land, conservation easements, plat-required lake access).
5. ✅ **Segment cleanup.** Adjacent segments merge into runs (`90_merge.sql`) when
   category, municipality, owner label, and access source and note match. Private
   shore keeps its labels (Condo / HOA, Church) rather than becoming one run.
6. ✅ **Scorecard on the site.** Interactive tables and charts computed in the browser from
   user-chosen numerators and denominators (e.g. "open shore ÷ all shore", "provided by the
   municipality ÷ all shore", lakes only), plus default reports with preset choices. The
   pipeline ships a tidy per-municipality breakdown (`stats.json`); the site aggregates.
   Map: shade municipalities by the selected measure. Metric/imperial display switch
   (data stays in meters). Done 2026-10-19, plus: settings in the URL, a ranked chart
   with full-row tooltips, a "what the shore is made of" stacked chart, and a shore
   floor slider.
7. **Ship.** Approve the output, commit `site/public/data/`, enable GitHub Pages, restore
   the push trigger.
   - Done: `site/public/data/` committed; `push` trigger restored in
     `.github/workflows/deploy.yml`; Pages enabled with GitHub Actions as the source
     (2026-10-18).
   - To do: confirm the repo is public (the About page links to it), push, check the
     deployed site at https://loriendraeger.github.io/public-private-shore/.
8. **Explain and polish.** Methodology/about page (sources and vintages, coastline
   paradox, public trust doctrine, how scores are computed, disclaimer), README,
   data-validation tests, CI (ruff + unit tests), mobile layout.
   - Done: About page (`#/about`; pipeline settings and source links come from
     stats.json); README; mobile layout for the scorecard (names above bars, tap
     tooltips) and the map (panel under the map, selecting a segment scrolls to it).
   - To do: data-validation tests (only the ownership-rule unit tests exist), CI (ruff +
     unit tests; there is no `ci.yml` yet), a look at the map on real phones (maybe a
     bottom sheet for segment details), the README against what the site now does.

## Decisions log

Record judgment calls here (classification edge cases, tolerance changes, scope
changes), newest first, with the date and a one-line rationale.

- 2026-10-18: Private land open to the public (`private_public_access`) counts as public
  access in the default reports, like land trusts: the public can reach the water there.
  A "public land only" report leaves out both.

- 2026-10-18: The scorecard's default report is "Public access, including ponds"
  (supersedes ponds being off in the default reports); the other presets still leave
  ponds out.

- 2026-10-18: The site no longer mentions `unknown` (legends, scorecard column and
  summary, category list): the pipeline leaves none. `unknown` stays a pipeline
  fallback (`70_category.sql`) and an owner class.

- 2026-10-18: Licensing is share-alike throughout: code GPL-3.0-or-later (`LICENSE`),
  docs and methodology CC BY-SA 4.0 (`LICENSE-DOCS`), data ODbL 1.0 (`LICENSE-DATA`:
  `site/public/data/` and the curated `config/*.csv`). The outputs derive from OSM, so
  ODbL is required anyway; `LICENSE-DATA` lists the upstream attributions, whose terms
  still apply. New data sources need a line there too.

- 2026-10-18: Highway right-of-way at the water (numbered routes, by OSM `ref`:
  interstate, US, state, county trunk; mostly bridges over creeks and the Yahara) is
  public land with no access, not a street end: 94 runs, 4.2 km. Roads running along
  the shore (John Nolen Dr, Vilas Park Dr) stay open street ends.
- 2026-10-18: Snap re-check on Mendota and Monona: 95% of shore is within 5 m of a
  parcel, so the 15 m tolerance only matters at the edges, but there it let lots beside
  unparceled street ends claim them: none of the lakes' 29 street ends came out as
  right-of-way. Shore steps now take the parcel **behind** them (a fan of inland rays,
  +-15 degrees, 15 m: transects, as in USGS DSAS), and a parcel that extends into the
  water owns its shore (rural ponds inside farm parcels, which otherwise looked like
  street ends along county roads). 14 of the 29 street ends are now public ROW (S.
  Dickinson, Few, Ingersoll, Lake St, ...); ROW 5.6 -> 10.1 km, municipal +3.7 km. The
  old method stays available as snap_method = "nearest" (make compare).
- 2026-10-18: Overrides are keyed by parcel (statewide `stateid`), not by a point on a
  segment, so snap-tolerance or merge changes can't move them; a point is the fallback
  for shore with no parcel. Optional owner columns. The 17 point overrides became 16
  parcel rows; the Sun Prairie one now covers its parcel's whole shore (1.2 km, was
  already no access).
- 2026-10-18: **Zero unknowns.** Hook Lake's unparceled bog edges (12.4 km) are left out
  of the analysis (`config/shore_exclusions.csv`). The rest is decided by rules, then
  spot-checked: owner-name rules (`config/access_owner_rules.csv`: DNR, US Fish &
  Wildlife, parks open; Corrections, golf, stormwater, landfill, Humane Society,
  WisDOT/rail, redevelopment none), "next to a park" (public land within 50 m of an
  OSM park or nature area is open), and "no evidence" (anything left is none).
  Unknown-owner shore counts as other public when open, private when not. Private
  land with public access was reviewed and confirmed. The review list now holds the
  25 biggest or least certain automatic decisions.
- 2026-10-18: Public strips between private lots reviewed: all private except Stoughton's
  Yahara strip (overrides).
- 2026-10-18: Railway barriers reviewed on the map: all correct (15 runs, 2.2 km).
  They leave the review list.
- 2026-10-18: Access wording comes from data (`config/access_display.csv`), not the
  site: e.g. private shore reads "None", OSM `nature_reserve` reads "Nature area: …",
  unnamed footways/cycleways read "Public path". Runs split where the park (or trail,
  street) changes. "Private (owner withheld)" is relabeled "Private" (merges with its
  neighbors). Unknown-owner shore that OSM marks open, and all private-with-public-access
  shore, go to the review list.
- 2026-10-18: Segments merge into runs for the map and stats (milestone 5): adjacent
  segments with the same category, municipality, narrow flag, owner class and label,
  and access source and reason. Private keeps its labels, so Condo / HOA and Church
  stay visible (supersedes "adjacent private segments merged regardless of
  owner"). Centerline runs under 10 m take the run before them (499 pieces were under
  5 m); the other bank is listed, not part of the key. Banks 3,489 -> 1,822 runs,
  centerlines 2,198 -> 1,162. Segments stay as the audit layer.
- 2026-10-18: Unknowns under 10 m between two segments with the same owner class,
  label and known access take theirs (access source and note too), if they're gaps or already share the class (12
  segments, 38 m; map tidying more than a dent in the unknowns). Public strips between
  two private lots never inherit "private": they're often public lake-access lots and
  get their own section in the review list.
- 2026-10-18: **Rail causeways aren't shore**, like unbridged islands: land under 30 m
  wide with water on both sides and at least 50 m of railway on it (found by opening
  the land near tracks). Removes ~1.2 km of track bed across Monona Bay (the Wisconsin
  & Southern trestles); the John Nolen Drive causeway (road + trail) stays. Also: shore
  next to a rail bridge isn't "within 10 m of tracks" (the tracks cross, not run
  along), and centerline steps on county Lake-type water count as wide like the banks
  (Starkweather Creek below the Capital City Trail had centerline + both banks).
- 2026-10-18: Access goal is **zero `unknown`**, by manual review where evidence runs out.
  Three new evidence rules (milestone 4, first pass): (1) **shore paths**: public land
  still unknown is open when a public footway/cycleway is within 30 m and not across
  tracks (33 km; the distances break between 20 and 30 m); (2) **railway barriers**:
  open shore is `none` where the tracks are within 10 m of it or every public way
  within 50 m is across them, judged on points every 10 m (3 km, incl. the John
  Nolen Drive causeway on Monona Bay); a local test, not land-side reachability;
  it applies to unknown shore too (no land route either way) and skips segments
  under 5 m (slivers where a segment ends at the tracks);
  (3) on **private land**, OSM parks, reserves, beaches and slipways count only when
  named (unnamed parks there are mostly HOA greens; 15.2 -> 12.1 km).

- 2026-10-17: Analysis uses scorecard categories (see [Scorecard categories](#scorecard-categories)),
  derived from ownership class + access; owner labels and access reasons are map-only.
  State and federal merge into `state_federal`; street ends go under `municipal`; land
  trusts get their own `land_trust` category (counted as public), separate from
  `private_public_access`. UW is its own category; Edgewood College is private.
- 2026-10-17: Access is `open` / `none` / `unknown`; `restricted` is dropped. Fees open
  to anyone count as `open`; members-, students- or residents-only count as `none`.
  Marinas and boat rentals are no longer access evidence. Schools and institutional
  grounds (e.g. Mendota Mental Health Institute) default to `public_no_access`, open to
  per-case overrides.
- 2026-10-17: Edgewood Condo Assn land on Lake Wingra is the Edgewood campus's shared
  lakefront (college + schools), not a residential condo: label "Edgewood (campus common
  land)", private with public access (override). Edgewood College owns no shore itself.
  No other private college owns shore in the study area.
- 2026-10-18: Only flowing water collapses onto a centerline: shore of county
  hydtype Lake polygons (lakes, ponds, their narrow arms and inlets) always keeps both
  banks at full weight; River (or no hydtype, the main Yahara) can be narrow. Fixes
  centerlines through pond lobes hiding pond shore. Narrow banks counted at half weight:
  ~49 -> 12 km.
- 2026-10-18: Short runs are absorbed before segments form: owner and narrow/wide runs
  under 10 m (`segment_min_run_m`) take their neighbor's value; gaps (possible street
  ends) are exempt. Segments under 10 m: 496 -> 132; category totals move < 0.5 km.
- 2026-10-18: The shoreline is simplified and smoothed before anything is measured:
  Visvalingam-Whyatt (10 m²; 1 m² left visible wiggles), densify to 8 m edges,
  Chaikin x2 (`shore_*` in `pipeline.toml`). Removes digitizing jitter and needle spikes
  (Tiedeman Pond's marsh edge had a vertex every 0.9 m); total shore 750 -> 735 km (-2%),
  99% of lines move < 8 m (inside the 15 m snap tolerance); unparceled gaps didn't grow. Done in the
  analysis, not just the tiles, so the map and the numbers agree.
- 2026-10-18: Water in scope = named water (county or DNR name, any size, plus unnamed
  pieces of it that OSM names) and **ponds**: standalone water of at least 1 ha
  (`pond_min_area_m2`) the county and DNR don't name, labeled with the OSM name or
  "Unnamed pond" (207 ponds, ~185 km of shore). Ponds are their own water type, opt-in
  on the scorecard (off in the default reports). Rejected: "in a park + 1 ha" as an
  inclusion rule, because it admits only ponds that score as public access, so a
  municipality that backs its ponds with private lots would pay no price; counting all
  ponds credits the park choice and penalizes the private one. Names (OSM or pattern-
  matched "retention") are not used to judge which ponds matter.
- 2026-10-17: Narrow water (under 30 m) counts ONCE: the two banks collapse onto the
  Dane County stream centerline, which takes the better bank (public access if EITHER
  bank has it; priority in `pipeline.toml`) and its municipality. Width is measured
  along the centerline (left + right distance to shore), smoothed (100 m rolling median,
  100 m minimum run), and banks take the nearest centerline's decision; morphological
  opening is the fallback where there's no centerline (those banks count half, ~29 km).
  Tried 20 m first: the Yahara through Cherokee Marsh (20-26 m) stayed two banks
  between collapsed reaches; 30 m adds only ~6 km of centerline. Measured shore drops
  from 531 to ~374 km. The scorecard's lake/river split is now wide/narrow (the county
  hydtype mislabeled ~87 km of the Yahara as lake).
- 2026-10-17: Population comes from WI DOA final estimates (1/1/2026, Dane County
  part of each municipality), not Census 2020: DOA follows current boundaries (the Town
  of Madison dissolved into Madison and Fitchburg in 2022).
- 2026-10-17: The scorecard leaves `unknown` shore out of every measure for now
  (reported per municipality), until the unknowns are cleaned up. A shore-floor slider
  (default 1 km of measured shore) leaves out municipalities whose share would swing on
  one park or street end.
- 2026-10-17: All data is stored and shipped in meters; the site offers a metric/imperial
  display switch (m/km ↔ ft/mi).
- 2026-10-17: Scorecard lives on the site, computed in the browser from user-chosen
  numerators/denominators plus default reports. Libraries: Observable Plot (charts),
  TanStack Table (tables), plain TypeScript aggregation over a tidy `stats.json`.
- 2026-10-17: Adjacent private segments will be merged regardless of owner; individual
  private owners don't matter, only private vs. public and access. (Superseded
  2026-10-18: private runs keep their labels.)

- 2026-10-17: Project goal reframed: a municipal scorecard of public water access, not a
  guide to access spots. Two measures (any public access; municipality-provided), each as
  % of shoreline and absolute km.
- 2026-10-17: Islands are excluded (reaching them needs a boat), unless an OSM road or
  path crosses onto them (bridge or causeway). `analysis.islands` records each one.

- 2026-10-17: Owner 'NOT AVAILABLE' (name withheld; 25,034 parcels, 11% of the county)
  is `private`, label "Private" (was "Private (owner withheld)"; relabeled 2026-10-18 so it
  merges with neighboring private shore). Along the shore they're nearly all
  taxable residential, and none bill to an institutional address.
- 2026-10-17: Conservation land trusts (Groundswell / Natural Heritage Land Trust, The
  Nature Conservancy, Driftless Area Land Conservancy) are `other_public`, label "Land
  trust" (superseded: now their own `land_trust` category, above). Matched by trust name, since generic "CONSERVANCY" also hits HOAs and LLCs.

- 2026-10-17: Study area = 30 municipalities chosen on the map (central Dane County
  around the Yahara lakes, plus City of Stoughton and Village of Oregon; edge towns
  Pleasant Springs, Cottage Grove, Bristol and Sun Prairie in). Replaces "all of Dane
  County". Judged from the land side; segments whose adjacent land is outside are dropped.
- 2026-10-17: Water scope = every named water polygon (lake, pond, polygon river;
  county or DNR name; ponds added 2026-10-18) in the study area, any size. Unnamed water (mostly stormwater) out.
  DNR's literal 'Unnamed' is treated as no name.

- 2026-10-17: Snap tolerance 5 m → 15 m, chosen on the map. At Wingra, 15 m is the
  smallest value that closes every small-inlet gap (max 13 m) while keeping the real
  ROW gap (117 m at 5, 81 at 15; at 25 it shrinks to 51 and fragments). Re-check on
  denser shores in milestone 3.

- 2026-10-17: OSM access evidence can open private land (e.g. the Edgewood Forest
  reserve on condo-association land, which really is publicly accessible). Expect
  some segments to need manual review; fix them in `config/access_overrides.csv`.
- 2026-10-17: Condo/HOA common land is class `private` (label "Condo / HOA"), not a
  separate class.
- 2026-10-17: Piers are access evidence on non-private land only (`public_only` in
  `config/access_osm.csv`); private docks don't open private shore. Marinas and boat
  rentals count as `restricted` (fee-based) (superseded: `restricted` dropped, above).

- 2026-10-17: Line-only streams are excluded for now (575 km of named creeks such as
  Pheasant Branch and Six Mile Creek; two banks would be ~1,150 km, more than all lake
  shore). Shoreline comes only from water polygons. Revisit later.

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
