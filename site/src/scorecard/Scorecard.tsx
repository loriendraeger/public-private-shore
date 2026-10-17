import { For, type JSX, Show } from 'solid-js'

import { CATEGORIES, KNOWN_CATEGORIES } from '../lib/categories'
import type { Category } from '../lib/contract'
import { formatLong, formatPct, formatShort } from '../lib/units'
import {
  measure,
  type Metric,
  metric,
  scores,
  setMeasure,
  setMetric,
  stats,
  units,
} from '../state/store'
import Chart from './Chart'
import { LITTLE_SHORE_M, matchingReport, REPORTS, totalScore, type WaterFilter } from './measures'
import ScoreTable from './ScoreTable'

const WATER: Record<WaterFilter, string> = { all: 'All water', lake: 'Lakes', river: 'Rivers' }
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
          <For each={KNOWN_CATEGORIES}>
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
          <tr class="muted">
            <td title={CATEGORIES.unknown.description}>Unknown</td>
            <td colspan="2">excluded for now</td>
          </tr>
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

function Summary(): JSX.Element {
  function t(): ReturnType<typeof totalScore> {
    return totalScore(scores())
  }
  return (
    <p class="summary">
      All {scores().length} municipalities:{' '}
      <strong>{t().pct === null ? '—' : formatPct(t().pct ?? 0)}</strong> (
      {formatLong(t().numeratorM, units())} of {formatLong(t().denominatorM, units())}),{' '}
      {formatShort(t().perThousandM, units())} per 1,000 residents.{' '}
      <span class="muted">{formatLong(t().unknownM, units())} of unknown shore left out.</span>
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
          <Segmented
            label="Water"
            options={WATER}
            value={measure().water}
            onChange={(w) => setMeasure({ ...measure(), water: w })}
          />
        </div>
        <Builder />

        <Summary />

        <div class="controls">
          <span class="label">Rank by</span>
          <Segmented label="Rank by" options={METRICS} value={metric()} onChange={setMetric} />
        </div>
        <Chart scores={scores()} />
        <p class="fine">
          * Less than {formatLong(LITTLE_SHORE_M, units())} of measured shore: one park or street
          end swings the share a lot.
        </p>

        <h2>All municipalities</h2>
        <ScoreTable scores={scores()} />
      </Show>
    </div>
  )
}
