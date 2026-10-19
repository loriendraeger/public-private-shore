# Public Water Access Around Madison

Check it out at [https://loriendraeger.github.io/public-private-land/](https://loriendraeger.github.io/public-private-land/).

This is not meant to be advice about where you are allowed to be.

## Why?

I've been curious about what kind of public access municipalities around Madison have for their water. Now we can all see who provides the most access and who allows it all to be privately owned.

There were a lot of small decisions that went into making the data sort of clean. A log of those decisions is in [AGENTS.md#decisions-log](AGENTS.md#decisions-log). The config directory holds all of that work and there's probably fun to be had tweaking different variables and rerunning analysis. I am not a GIS expert by any means, so there's a real chance that those decisions were wrong, but the map looks pretty good to me.

## How?

This is almost 100% vibe coded over a weekend. A full architecture explanation is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Running Analysis and Generating Basemap

The analysis pipeline is designed to be run in Docker. It's PostGIS and Python.

Before running for the first time, run `cp .env.example .env` and modify it if you want.

1. Download all data from sources listed in [config/sources.toml](config/sources.toml) and put it in the data/raw folder in the `local_path` specified in that sources file. Skip the `basemap` entry.
2. `make all` (takes a while)

After you run the analysis you can generate the basemap tiles with `make basemap`, which downloads Protomaps tiles and clips it to the bounds of the data.

The output of both is saved in `site/public/data`.

Turn off the db container with `make db-down`.

## Running the Site

The site requires Node 24. It's a SolidJS single page app built with Vite.

```
cd site
npm ci
npm run dev
```

## Contributing

This is not a serious project, but sure whatever. I make no promises that I will review your PR.

## License

Copyright (c) 2026 Lorien Draeger

This project is share-alike throughout:

| What | License | File |
|---|---|---|
| Code (`pipeline/`, `site/`, build files) | GPL-3.0-or-later | [LICENSE](LICENSE) |
| Documentation and methodology | CC BY-SA 4.0 | [LICENSE-DOCS](LICENSE-DOCS) |
| Data (`site/public/data/`, `config/*.csv`) | ODbL 1.0 | [LICENSE-DATA](LICENSE-DATA) |

The data is derived from OpenStreetMap (© OpenStreetMap contributors) and from public Wisconsin and Dane County datasets, which keep their own terms. See [LICENSE-DATA](LICENSE-DATA) for the full list of sources and required attribution.
