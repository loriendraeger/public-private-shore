#!/bin/sh
# AD HOC (not part of the pipeline): export review GeoJSON for QGIS.
# Run from the repo root after `make analysis`:
#   pipeline/adhoc/review_exports/export.sh            # all *.sql here
#   pipeline/adhoc/review_exports/export.sh land_trust_parcels
# Writes data/build/review/<name>.geojson (EPSG:4326). Local only: may contain owner
# names and billing addresses.
set -eu
dir=pipeline/adhoc/review_exports
out=data/build/review
mkdir -p "$out"

if [ $# -eq 0 ]; then
  set -- $(cd "$dir" && ls *.sql | sed 's/\.sql$//')
fi

for name in "$@"; do
  echo "== $name"
  rm -f "$out/$name.geojson"
  docker compose run --rm -T pipeline \
    ogr2ogr -f GeoJSON "$out/$name.geojson" PG: -t_srs EPSG:4326 -nln "$name" \
      -sql "@$dir/$name.sql"
done
