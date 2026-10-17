import { For, type JSX, Show } from 'solid-js'

import { ACCESS, entries, type Mode, OWNER_GROUPS } from '../map/colors'
import {
  colorBy,
  hasAlt,
  selected,
  setColorBy,
  setShowAlt,
  setShowMunis,
  showAlt,
  showMunis,
} from '../state/store'

const mode: Mode = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'

const ACCESS_SOURCE: Record<string, string> = {
  default: 'default for this kind of owner',
  osm: 'OpenStreetMap',
  street_end: 'public street end',
  override: 'manual review',
}

const CLASS_LABEL: Record<string, string> = {
  school_district: 'school district',
  other_public: 'other public',
  row: 'road right-of-way',
}

function Legend(): JSX.Element {
  return (
    <ul class="legend">
      <Show
        when={colorBy() === 'owner'}
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
        <For each={entries(OWNER_GROUPS)}>
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
            <dt>Owner</dt>
            <dd>
              {s().owner_label}{' '}
              <span class="muted">({CLASS_LABEL[s().owner_class] ?? s().owner_class})</span>
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
            <dd>{s().waterbody}</dd>
            <dt>Length</dt>
            <dd>
              {Math.round(s().length_m).toLocaleString()} m (
              {(s().length_m * 3.28084).toLocaleString(undefined, { maximumFractionDigits: 0 })} ft)
            </dd>
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
        Who owns the land along the water, and whether the public can reach it. Lake Wingra only,
        for now.
      </p>

      <div class="segmented" role="radiogroup" aria-label="Color shoreline by">
        <button
          role="radio"
          aria-checked={colorBy() === 'owner'}
          onClick={() => setColorBy('owner')}
        >
          Ownership
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

      <label class="toggle">
        <input
          type="checkbox"
          checked={showMunis()}
          onChange={(e) => setShowMunis(e.currentTarget.checked)}
        />
        Municipal boundaries
      </label>

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
