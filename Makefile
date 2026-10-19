# Single entry point for the pipeline. Recipes are thin: the work happens in
# `shore <cmd>` inside the pipeline container, so host tool versions don't matter.
#
# Make can't see inside PostGIS, so each DB stage touches a stamp file in
# data/build/.stamps/. A stamp depends on its stage's SQL, on config/, and on the
# previous stamp: editing one SQL file reruns that stage and everything after it.

COMPOSE := docker compose
RUN     := $(COMPOSE) run --rm pipeline uv run --project pipeline shore
STAMPS  := data/build/.stamps
CONFIG  := $(wildcard config/*)
SQL      = $(wildcard pipeline/sql/$(1)/*.sql)

.PHONY: all db-up db-down db-reset psql image load init staging analysis export stats tiles basemap compare test lint

all: tiles stats

db-up:
	$(COMPOSE) up -d --wait db

db-down:
	$(COMPOSE) down

db-reset:  ## drop the database volume and all stamps
	$(COMPOSE) down -v
	rm -rf $(STAMPS)

psql: db-up
	$(COMPOSE) exec db psql -U $${PGUSER:-shore} -d $${PGDATABASE:-shore}

image:
	$(COMPOSE) build pipeline

init:     $(STAMPS)/init
load:     $(STAMPS)/load
staging:  $(STAMPS)/staging
analysis: $(STAMPS)/analysis

$(STAMPS)/init: $(call SQL,00_init) | db-up
	$(RUN) sql 00_init
	@mkdir -p $(@D) && touch $@

# Reloading is slow (~1 min) and only needed when downloads change.
$(STAMPS)/load: $(STAMPS)/init config/sources.toml
	$(RUN) load
	@touch $@

$(STAMPS)/staging: $(STAMPS)/load $(call SQL,10_staging) $(CONFIG)
	$(RUN) sql 10_staging
	@touch $@

$(STAMPS)/analysis: $(STAMPS)/staging $(call SQL,20_analysis) $(CONFIG)
	$(RUN) sql 20_analysis
	@touch $@

# Products. export/tiles are cheap, so they always rerun.
export: $(STAMPS)/analysis
	$(RUN) sql 30_export
	$(RUN) export

stats: export
	$(RUN) stats

tiles: export
	$(RUN) tiles $(if $(COMPARE),--compare)

# Extract region = the study area (+ margin), so it needs the analysis stage.
basemap: $(STAMPS)/analysis
	$(RUN) basemap

# Extra map layer `shore_alt` at another tolerance, e.g. make compare SET=snap_tolerance_m=12,
# then `make tiles COMPARE=1` to see it on the map. A plain `make tiles` leaves it out.
SET ?= snap_tolerance_m=12
compare: $(STAMPS)/analysis
	$(RUN) compare --set $(SET)

test:
	$(COMPOSE) run --rm pipeline uv run --project pipeline pytest pipeline/tests

lint:
	$(COMPOSE) run --rm pipeline uv run --project pipeline ruff check pipeline
