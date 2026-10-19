#!/bin/sh
# AD HOC (not part of the pipeline): write the access review list.
# Run from the repo root after `make export`:
#   pipeline/adhoc/access_review/review.sh
#   SITE=https://example.github.io/public-private-shore/ pipeline/adhoc/access_review/review.sh
# Writes data/build/review/access_review.md. Local only.
set -eu
out=data/build/review
mkdir -p "$out"
site=${SITE:-http://localhost:5173/public-private-shore/}
crs=$(sed -n 's/^crs *= *\([0-9]*\).*/\1/p' config/pipeline.toml)
docker compose exec -T db psql -U "${PGUSER:-shore}" -d "${PGDATABASE:-shore}" -X -At \
  -v ON_ERROR_STOP=1 -v site="$site" -v crs="$crs" \
  < pipeline/adhoc/access_review/access_review.sql > "$out/access_review.md"
echo "wrote $out/access_review.md"
