import { For, type JSX, Show } from 'solid-js'

import { ALL_CATEGORIES, CATEGORIES } from '../lib/categories'
import type { Category, WaterKind } from '../lib/contract'
import { formatLong, formatPct, formatShort, fromLong, longUnit, toLong } from '../lib/units'
import {
  measure,
  type Metric,
  metric,
  minShoreM,
  scores,
  setMeasure,
  setMetric,
  setMinShoreM,
  stats,
  units,
} from '../state/store'
import Chart from './Chart'
import Composition from './Composition'
import {
  DEFAULT_MIN_SHORE_M,
  matchingReport,
  MAX_MIN_SHORE_M,
  REPORTS,
  totalScore,
} from './measures'
import ScoreTable from './ScoreTable'

const WATER: Record<WaterKind, { label: string; title: string }> = {
  wide: { label: 'Lakes & wide rivers', title: 'Named lakes, ponds and rivers at least 30 m wide' },
  narrow: {
    label: 'Narrow streams',
    title: 'Water under 30 m wide, counted once along its centerline',
  },
  pond: {
    label: 'Ponds',
    title: "Standalone water of 1 ha or more that the county and DNR don't name (often stormwater)",
  },
}

/** Which water types count. At least one stays checked. */
function WaterPicker(): JSX.Element {
  return (
    <fieldset class="water">
      <legend class="label">Water</legend>
      <For each={Object.keys(WATER) as WaterKind[]}>
        {(k) => (
          <label title={WATER[k].title}>
            <input
              type="checkbox"
              checked={measure().water.includes(k)}
              disabled={measure().water.length === 1 && measure().water.includes(k)}
              onChange={(e) => {
                const m = measure()
                const on = e.currentTarget.checked
                setMeasure({
                  ...m,
                  // keep the canonical order so presets still match
                  water: (Object.keys(WATER) as WaterKind[]).filter((x) =>
                    x === k ? on : m.water.includes(x),
                  ),
                })
              }}
            />
            {WATER[k].label}
          </label>
        )}
      </For>
    </fieldset>
  )
}
const METRICS: Record<Metric, string> = {
  pct: 'Share of shore',
  distance: 'Distance',
  perThousand: 'Per 1,000 residents',
}

function toggle(list: Category[], c: Category, on: boolean): Category[] {
  return on ? [...list.filter((x) => x !== c), c] : list.filter((x) => x !== c)
}

function ReportPicker(): JSX.Element {
  function current(): string {
    return matchingReport(measure())?.id ?? 'custom'
  }
  return (
    <div class="report">
      <label>
        <span class="label">Report</span>
        <select
          value={current()}
          onChange={(e) => {
            const r = REPORTS.find((x) => x.id === e.currentTarget.value)
            if (r) {
              setMeasure(r.measure)
            }
          }}
        >
          <For each={REPORTS}>{(r) => <option value={r.id}>{r.label}</option>}</For>
          <option value="custom" disabled>
            Custom
          </option>
        </select>
      </label>
      <p class="muted">
        {matchingReport(measure())?.description ??
          'Your own choice of what counts, out of what (below).'}
      </p>
    </div>
  )
}

/** Category grid: which categories count (numerator) and what they're out of
 * (denominator). The numerator is kept a subset of the denominator. */
function Builder(): JSX.Element {
  return (
    <details class="builder">
      <summary>Customize: what counts, out of what</summary>
      <table class="cats">
        <thead>
          <tr>
            <th>Category</th>
            <th>Counts</th>
            <th>Out of</th>
          </tr>
        </thead>
        <tbody>
          <For each={ALL_CATEGORIES}>
            {(c) => (
              <tr>
                <td title={CATEGORIES[c].description}>{CATEGORIES[c].label}</td>
                <td>
                  <input
                    type="checkbox"
                    aria-label={`Count ${CATEGORIES[c].label}`}
                    checked={measure().numerator.includes(c)}
                    onChange={(e) => {
                      const on = e.currentTarget.checked
                      const m = measure()
                      setMeasure({
                        ...m,
                        numerator: toggle(m.numerator, c, on),
                        denominator: on ? toggle(m.denominator, c, true) : m.denominator,
                      })
                    }}
                  />
                </td>
                <td>
                  <input
                    type="checkbox"
                    aria-label={`Out of ${CATEGORIES[c].label}`}
                    checked={measure().denominator.includes(c)}
                    onChange={(e) => {
                      const on = e.currentTarget.checked
                      const m = measure()
                      setMeasure({
                        ...m,
                        denominator: toggle(m.denominator, c, on),
                        numerator: on ? m.numerator : toggle(m.numerator, c, false),
                      })
                    }}
                  />
                </td>
              </tr>
            )}
          </For>
        </tbody>
      </table>
    </details>
  )
}

function Segmented<T extends string>(props: {
  label: string
  options: Record<T, string>
  value: T
  onChange: (v: T) => void
}): JSX.Element {
  return (
    <div class="segmented" role="radiogroup" aria-label={props.label}>
      <For each={Object.keys(props.options) as T[]}>
        {(k) => (
          <button
            role="radio"
            aria-checked={props.value === k}
            onClick={() => {
              props.onChange(k)
            }}
          >
            {props.options[k]}
          </button>
        )}
      </For>
    </div>
  )
}

/** Floor on measured shore, set in the display unit (km or mi). */
function ShoreFloor(): JSX.Element {
  function value(): number {
    return toLong(minShoreM(), units())
  }
  return (
    <label class="floor">
      <span class="label">Only municipalities with at least</span>
      <input
        type="range"
        min="0"
        max={toLong(MAX_MIN_SHORE_M, units())}
        step="0.25"
        value={value()}
        onInput={(e) => {
          setMinShoreM(fromLong(e.currentTarget.valueAsNumber, units()))
        }}
      />
      <output>
        {value().toLocaleString(undefined, { maximumFractionDigits: 2 })} {longUnit(units())}
      </output>
      <span>of measured shore</span>
      <span class="muted">
        (below {formatLong(DEFAULT_MIN_SHORE_M, units())}, one park or street end swings the share a
        lot)
      </span>
    </label>
  )
}

function Summary(): JSX.Element {
  function t(): ReturnType<typeof totalScore> {
    return totalScore(scores())
  }
  return (
    <p class="summary">
      {scores().length === (stats()?.municipalities.length ?? 0)
        ? `All ${String(scores().length)} municipalities`
        : `${String(scores().length)} of ${String(stats()?.municipalities.length ?? 0)} municipalities`}
      : <strong>{t().pct === null ? '—' : formatPct(t().pct ?? 0)}</strong> (
      {formatLong(t().numeratorM, units())} of {formatLong(t().denominatorM, units())}),{' '}
      {formatShort(t().perThousandM, units())} per 1,000 residents.
    </p>
  )
}

export default function Scorecard(): JSX.Element {
  return (
    <div class="scorecard">
      <Show when={stats()} fallback={<p class="hint">Loading…</p>}>
        <h1>Municipal scorecard</h1>
        <p class="lede">
          How much of each municipality's shoreline the public can reach from land, judged by the
          land each stretch of shore borders.
        </p>

        <ReportPicker />
        <div class="controls">
          <WaterPicker />
          <ShoreFloor />
        </div>
        <Builder />

        <Summary />

        <div class="controls">
          <span class="label">Rank by</span>
          <Segmented label="Rank by" options={METRICS} value={metric()} onChange={setMetric} />
        </div>
        <Chart scores={scores()} />

        <h2>All municipalities</h2>
        <ScoreTable scores={scores()} />

        <h2>What the shore is made of</h2>
        <Composition scores={scores()} />
      </Show>
    </div>
  )
}
