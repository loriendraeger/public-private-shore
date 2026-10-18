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
/** Set from the route by UrlSync (state/url.ts); navigate to change it. */
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

/** Municipality the map is focused on (muni_id): its shore stands out, the rest fades. */
export const [focusMuni, setFocusMuni] = createSignal<number | null>(null)

/** West, south, east, north (WGS84). */
export type Bbox = [number, number, number, number]

/** What the map currently shows; written by the map on every move. */
export const [mapBbox, setMapBbox] = createSignal<Bbox | null>(null)

/** Move the map here (from the URL or the municipality picker); the map applies it. */
export interface CameraRequest {
  bbox: Bbox
  padding: number
  maxZoom?: number
  animate: boolean
}
export const [cameraRequest, setCameraRequest] = createSignal<CameraRequest | null>(null)

/** A segment to select once its tiles are loaded (from the URL's `seg`). */
export const [segRequest, setSegRequest] = createSignal<number | null>(null)

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

/** Zoom the map to a municipality's shore. */
export function zoomToMuni(id: number | null): void {
  const bbox = stats()?.municipalities.find((m) => m.muni_id === id)?.shore_bbox
  if (bbox) {
    setCameraRequest({ bbox, padding: 60, maxZoom: 15, animate: true })
  }
}

export async function loadStats(url: string): Promise<void> {
  const res = await fetch(url)
  if (!res.ok) {
    throw new Error(`stats.json: HTTP ${String(res.status)}`)
  }
  setStats((await res.json()) as Stats)
}
