import { A } from '@solidjs/router'
import { For, type JSX, Show } from 'solid-js'

import { ALL_CATEGORIES, CATEGORIES } from '../lib/categories'
import { narrowWidth, pondMinArea, snapTolerance } from '../lib/settings'
import { formatLong } from '../lib/units'
import { DEFAULT_MIN_SHORE_M } from '../scorecard/measures'
import { stats, units } from '../state/store'

// Methodology and credits. Source names, retrieval dates, and the numbers in the prose
// (lib/settings.ts) come from stats.json, so they follow the data.

/** Credit line per stats.json source key (LICENSE-DATA has the full terms). The dataset
 * links come from stats.json (config/sources.toml); a link here is for terms. */
const CREDIT: Record<string, { by: string; url?: string }> = {
  parcels: {
    by: "Wisconsin Statewide Parcel Map Initiative, WI Department of Administration / State Cartographer's Office",
  },
  hydro_county: { by: 'Dane County Land Information Office' },
  hydro: { by: 'Wisconsin DNR, 24K Hydrography', url: 'https://dnr.wisconsin.gov/legal' },
  municipalities: { by: 'Dane County Land Information Office' },
  osm: { by: '© OpenStreetMap contributors, ODbL', url: 'https://www.openstreetmap.org/copyright' },
  population: { by: 'WI Department of Administration, Demographic Services Center' },
}

const USED_FOR: Record<string, string> = {
  parcels: 'Who owns the land behind each stretch of shore',
  hydro_county: 'The shoreline itself',
  hydro: 'Official names of lakes and rivers',
  municipalities: 'Which municipality the shore belongs to',
  osm: 'Parks, paths, boat launches, beaches, roads, and railways (evidence of access)',
  population: 'Per-resident measures',
}

const REPO = 'https://github.com/loriendraeger/public-private-land'

export default function About(): JSX.Element {
  return (
    <article class="about">
      <h1>About</h1>
      <p class="lede">
        This site compares how much shoreline the municipalities of central Dane County, Wisconsin
        open to the public. For each city, village, and town around the Yahara lake chain, it
        measures how much of the shore the public can reach from land and who provides that access.
      </p>

      <h2>How it works</h2>
      <ul class="steps">
        <li>
          <strong>Shoreline.</strong> Shore comes from Dane County's detailed water maps: named
          lakes, rivers, and streams, plus unnamed ponds of at least {pondMinArea()}. Many of those
          are stormwater ponds. The default report counts them (a pond ringed by a park is access,
          one behind private lots isn't), but you can leave them out. Islands count only if a road
          or path reaches them.
        </li>
        <li>
          <strong>Who owns it.</strong> Each stretch of shore is matched to the parcel of land
          behind it (within {snapTolerance()}), and the parcel's owner is sorted into a type: the
          municipality, the county, the state, UW–Madison, a land trust, a private owner, and so on.
        </li>
        <li>
          <strong>Can the public get there?</strong> Owning land doesn't mean it's open, and private
          land is sometimes open. Access is judged from evidence: parks, beaches, and boat launches,
          public paths along the shore, or street ends that meet the water (generally public access
          in Wisconsin). Railway tracks and highway right-of-way cut access off. Shore with no
          evidence of access counts as not open, and the least certain cases were checked by hand.
        </li>
        <li>
          <strong>Which municipality.</strong> Shore belongs to the municipality on its land side.
          Municipal boundaries run out into the lakes, so the line alone can't say.
        </li>
        <li>
          <strong>Narrow water counts once.</strong> A creek has two banks, but it is one place to
          reach the water. Water under {narrowWidth()} wide is measured once, along its centerline,
          and counts as open if either bank is.
        </li>
      </ul>

      <h2>Categories</h2>
      <p>Every stretch of shore ends up in one category, from its owner and its access:</p>
      <dl class="cats-list">
        <For each={ALL_CATEGORIES}>
          {(c) => (
            <>
              <dt>{CATEGORIES[c].label}</dt>
              <dd>{CATEGORIES[c].description}</dd>
            </>
          )}
        </For>
      </dl>

      <h2>How scores are computed</h2>
      <p>
        A <A href="/scorecard">scorecard</A> report divides the shore that counts by the shore it's
        measured against. By default, it reports shore with public access out of all the
        municipality's shore. You can choose which categories count, which ones they're measured
        against, and which kinds of water are included. Per-resident figures divide the shore that
        counts by the municipality's population.
      </p>
      <p>
        Municipalities with little shore are left out by default (under{' '}
        {formatLong(DEFAULT_MIN_SHORE_M, units())}): there, a single park or street end swings the
        share a lot. You can adjust the floor.
      </p>

      <h2>Caveats</h2>
      <ul>
        <li>
          <strong>Shore length depends on the map.</strong> The more detailed the map, the longer
          the shoreline (the "coastline paradox"). All lengths here come from the same county maps
          (about 1:2,400), so they compare with each other, but not with figures from other sources.
          Before anything is measured, the shoreline is lightly smoothed to remove the tiny zigzags
          left by tracing it, which would otherwise add length that isn't really there. That
          shortens the total by about 2%, and moves almost every line by less than 8 m. The map
          shows the same smoothed shoreline the numbers are measured on.
        </li>
        <li>
          <strong>The data can be wrong or out of date.</strong> Parcel data is not a legal record
          of ownership, and OpenStreetMap is edited by volunteers. Some street ends are posted or
          vacated. Shoreline maps can lag behind development.
        </li>
        <li>
          <strong>Access here means from land.</strong> In Wisconsin, the beds of navigable lakes
          and rivers are held in trust for the public (the public trust doctrine). "No access from
          land" does not mean you can't be on the water, only that there's no public way to reach it
          from that stretch of shore.
        </li>
      </ul>
      <p class="disclaimer">
        This site is not legal advice. Don't rely on it to decide where you may go.
      </p>

      <h2>Data sources</h2>
      <Show when={stats()} fallback={<p class="hint">Loading…</p>}>
        {(s) => (
          <>
            <table class="sources">
              <thead>
                <tr>
                  <th>Dataset</th>
                  <th>Used for</th>
                  <th>Retrieved</th>
                </tr>
              </thead>
              <tbody>
                <For each={Object.entries(s().sources)}>
                  {([key, src]) => (
                    <tr>
                      <td>
                        <a href={src.url} target="_blank" rel="noreferrer">
                          {src.name}
                        </a>
                        <Show when={CREDIT[key]}>
                          {(c) => (
                            <div class="muted">
                              <Show when={c().url} fallback={c().by}>
                                {(url) => (
                                  <a href={url()} target="_blank" rel="noreferrer">
                                    {c().by}
                                  </a>
                                )}
                              </Show>
                            </div>
                          )}
                        </Show>
                      </td>
                      <td>{USED_FOR[key] ?? ''}</td>
                      <td class="nowrap">{src.retrieved}</td>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
            <p class="muted">
              Basemap: Protomaps, © OpenStreetMap contributors. Data last processed {s().generated}.
            </p>
          </>
        )}
      </Show>

      <h2>License and source</h2>
      <p>
        The data this site publishes is under the{' '}
        <a href="https://opendatacommons.org/licenses/odbl/1-0/" target="_blank" rel="noreferrer">
          Open Database License (ODbL)
        </a>
        ; the sources above keep their own terms. The code is GPL-3.0-or-later and this text is CC
        BY-SA 4.0. Everything is on{' '}
        <a href={REPO} target="_blank" rel="noreferrer">
          GitHub
        </a>
        , where you can also report mistakes.
      </p>
    </article>
  )
}
