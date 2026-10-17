import { createMemo, createRoot, createSignal } from 'solid-js'

import type { ShoreProps, Stats } from '../lib/contract'
import type { Units } from '../lib/units'
import {
  computeScores,
  DEFAULT_MIN_SHORE_M,
  type Measure,
  REPORTS,
  type Score,
} from '../scorecard/measures'

// App state as Solid signals. The map subscribes to these and updates paint/visibility
// in place; it is never re-created on a state change.

export type View = 'map' | 'scorecard'
export const [view, setView] = createSignal<View>('map')

export const [units, setUnits] = createSignal<Units>('metric')

export type ColorBy = 'category' | 'access'
export const [colorBy, setColorBy] = createSignal<ColorBy>('category')

/** Show the `shore_alt` layer (alternative pipeline settings) instead of `shore`. */
export const [showAlt, setShowAlt] = createSignal(false)
/** Whether shore.pmtiles contains a `shore_alt` layer at all. */
export const [hasAlt, setHasAlt] = createSignal(false)

export const [showMunis, setShowMunis] = createSignal(false)
/** Shade municipalities on the map by the current scorecard measure. */
export const [shadeMunis, setShadeMunis] = createSignal(false)

export const [selected, setSelected] = createSignal<ShoreProps | null>(null)

// Scorecard

export const [stats, setStats] = createSignal<Stats | null>(null)

export const [measure, setMeasure] = createSignal<Measure>(REPORTS[0].measure)

/** What the chart shows and ranks by. */
export type Metric = 'pct' | 'distance' | 'perThousand'
export const [metric, setMetric] = createSignal<Metric>('pct')

/** Leave out municipalities with less measured shore than this (meters; 0 = all). */
export const [minShoreM, setMinShoreM] = createSignal(DEFAULT_MIN_SHORE_M)

/** Scores for the current measure, above the shore floor; shared by the scorecard and
 * the map shading. */
export const scores = createRoot(() =>
  createMemo((): Score[] => {
    const s = stats()
    const floor = minShoreM()
    return s ? computeScores(s, measure()).filter((x) => x.denominatorM >= floor) : []
  }),
)

export async function loadStats(url: string): Promise<void> {
  const res = await fetch(url)
  if (!res.ok) {
    throw new Error(`stats.json: HTTP ${String(res.status)}`)
  }
  setStats((await res.json()) as Stats)
}
