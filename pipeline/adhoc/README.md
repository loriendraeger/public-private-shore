# Ad hoc analysis (not part of the pipeline)

One-off queries and exports used to make decisions, kept so they can be rerun and
audited. **Nothing here is run by `make`, and nothing here feeds the site.**

- Scripts read from the database (`staging`, `analysis`) after `make analysis`.
- Outputs go to `data/build/review/` (gitignored). They may contain raw owner names,
  billing addresses and other parcel details: **keep them local; never commit or
  publish them.**

| Directory | What it's for |
|---|---|
| `review_exports/` | GeoJSON of parcels behind an ownership decision, for review in QGIS |
| `access_review/` | `review.sh` → `data/build/review/access_review.md`: railway-barrier and unknown-access segments by municipality, each with a site link (`bbox` + `seg`) and a Google Maps satellite link |
