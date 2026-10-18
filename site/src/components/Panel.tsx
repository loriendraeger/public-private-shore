import { For, type JSX, Show } from 'solid-js'

import { CATEGORIES } from '../lib/categories'
import { formatLong, formatPct, formatShort } from '../lib/units'
import { ACCESS, CATEGORY_GROUPS, entries, type Mode, SEQUENTIAL } from '../map/colors'
import { computeScores, matchingReport } from '../scorecard/measures'
import {
  colorBy,
  focusMuni,
  hasAlt,
  measure,
  selected,
  setColorBy,
  setFocusMuni,
  setShadeMunis,
  setShowAlt,
  setShowMunis,
  shadeMunis,
  showAlt,
  showMunis,
  stats,
  units,
  zoomToMuni,
} from '../state/store'

const mode: Mode = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'

const ACCESS_SOURCE: Record<string, string> = {
  default: 'default for this kind of owner',
  osm: 'OpenStreetMap',
  path: 'public path to public land',
  street_end: 'public street end',
  barrier: 'cut off by a railway',
  override: 'manual review',
}

function Legend(): JSX.Element {
  return (
    <ul class="legend">
      <Show
        when={colorBy() === 'category'}
        fallback={
          <For each={entries(ACCESS)}>
            {([, a]) => (
              <li>
                <span class="swatch" style={{ background: a.color }} />
                <span class="icon" aria-hidden="true">
                  {a.icon}
                </span>
                {a.label}
              </li>
            )}
          </For>
        }
      >
        <For each={entries(CATEGORY_GROUPS)}>
          {([, g]) => (
            <li>
              <span class="swatch" style={{ background: g.color[mode] }} />
              {g.label}
            </li>
          )}
        </For>
      </Show>
    </ul>
  )
}

/** Pick a municipality to focus the map on, with its score for the current measure. */
function MuniFocus(): JSX.Element {
  function munis(): { muni_id: number; name: string }[] {
    return (stats()?.municipalities ?? [])
      .filter((m) => m.shore_bbox !== null)
      .sort((a, b) => a.name.localeCompare(b.name))
  }
  function score(): ReturnType<typeof computeScores>[number] | undefined {
    const s = stats()
    const id = focusMuni()
    return s && id !== null
      ? computeScores(s, measure()).find((x) => x.muni.muni_id === id)
      : undefined
  }
  return (
    <div class="focus">
      <label>
        <span class="label">Municipality</span>
        <select
          value={focusMuni() ?? ''}
          onChange={(e) => {
            const v = e.currentTarget.value
            const id = v === '' ? null : Number(v)
            setFocusMuni(id)
            zoomToMuni(id)
          }}
        >
          <option value="">All</option>
          <For each={munis()}>{(m) => <option value={m.muni_id}>{m.name}</option>}</For>
        </select>
      </label>
      <Show when={score()}>
        {(s) => (
          <p class="muted">
            {matchingReport(measure())?.label ?? 'Custom measure'}:{' '}
            <strong>{s().pct === null ? '—' : formatPct(s().pct ?? 0)}</strong> (
            {formatLong(s().numeratorM, units())} of {formatLong(s().denominatorM, units())})
          </p>
        )}
      </Show>
    </div>
  )
}

function SegmentDetails(): JSX.Element {
  return (
    <Show
      when={selected()}
      fallback={<p class="hint">Click a stretch of shoreline for details.</p>}
    >
      {(s) => {
        function access(): (typeof ACCESS)[keyof typeof ACCESS] {
          return ACCESS[s().access]
        }
        return (
          <dl class="details">
            <dt>Category</dt>
            <dd>{CATEGORIES[s().category].label}</dd>
            <dt>Owner</dt>
            <dd>
              {s().owner_label}
              <Show when={s().kind === 'stream'}>
                <div class="muted">
                  Narrow stream (under 30 m wide): counted once, with access if either bank has it.
                  <Show when={s().other_bank_label} fallback=" Only one bank is in the study area.">
                    {(o) => ` Other bank: ${o()}.`}
                  </Show>
                </div>
              </Show>
              <Show when={s().kind === 'bank' && s().narrow}>
                <div class="muted">
                  Narrow water with no mapped centerline: each bank counts half.
                </div>
              </Show>
            </dd>
            <dt>Access</dt>
            <dd>
              <span aria-hidden="true">{access().icon}</span> {access().label}
              <div class="muted">
                via {ACCESS_SOURCE[s().access_source] ?? s().access_source}
                <Show when={s().access_note}>{(note) => ` (${note()})`}</Show>
              </div>
            </dd>
            <dt>Municipality</dt>
            <dd>{s().muni_name}</dd>
            <dt>Waterbody</dt>
            <dd>
              {s().waterbody}
              <Show when={s().water_class === 'pond'}>
                <div class="muted">
                  Pond: not named by the county or DNR. Counted only when the scorecard includes
                  ponds.
                </div>
              </Show>
            </dd>
            <dt>Length</dt>
            <dd>{formatShort(s().length_m, units())}</dd>
          </dl>
        )
      }}
    </Show>
  )
}

export default function Panel(): JSX.Element {
  return (
    <aside class="panel">
      <h1>Dane County shore access</h1>
      <p class="lede">
        Who owns the land along the water, and whether the public can reach it. Named lakes, ponds
        and rivers in central Dane County.
      </p>

      <div class="segmented" role="radiogroup" aria-label="Color shoreline by">
        <button
          role="radio"
          aria-checked={colorBy() === 'category'}
          onClick={() => setColorBy('category')}
        >
          Category
        </button>
        <button
          role="radio"
          aria-checked={colorBy() === 'access'}
          onClick={() => setColorBy('access')}
        >
          Access
        </button>
      </div>
      <Legend />

      <MuniFocus />

      <label class="toggle">
        <input
          type="checkbox"
          checked={showMunis()}
          onChange={(e) => setShowMunis(e.currentTarget.checked)}
        />
        Municipal boundaries
      </label>

      <label class="toggle">
        <input
          type="checkbox"
          checked={shadeMunis()}
          onChange={(e) => setShadeMunis(e.currentTarget.checked)}
        />
        Shade by scorecard
      </label>
      <Show when={shadeMunis()}>
        <div class="ramp">
          <span class="muted">{matchingReport(measure())?.label ?? 'Custom measure'}</span>
          <div class="ramp-bar">
            <For each={SEQUENTIAL}>{(c) => <span style={{ background: c }} />}</For>
          </div>
          <div class="ramp-labels">
            <span>0%</span>
            <span>100%</span>
          </div>
        </div>
      </Show>

      <Show when={hasAlt()}>
        <div class="compare">
          <span>Snap tolerance</span>
          <div class="segmented" role="radiogroup" aria-label="Snap tolerance">
            <button role="radio" aria-checked={!showAlt()} onClick={() => setShowAlt(false)}>
              Current
            </button>
            <button role="radio" aria-checked={showAlt()} onClick={() => setShowAlt(true)}>
              Alternative
            </button>
          </div>
        </div>
      </Show>

      <h2>Selected</h2>
      <SegmentDetails />

      <p class="fine">
        Shore lengths come from Dane County's ~1:2,400 hydrography. Parcel data is not a legal
        record of ownership, and this map is not legal advice. In Wisconsin the beds of navigable
        waters are held in trust for the public: "no access from land" doesn't mean you can't be on
        the water.
      </p>
    </aside>
  )
}
