import { useLocation, useNavigate } from '@solidjs/router'
import { createEffect, on } from 'solid-js'

import { ALL_CATEGORIES } from '../lib/categories'
import type { Category, WaterKind } from '../lib/contract'
import {
  ALL_WATER,
  DEFAULT_MIN_SHORE_M,
  DEFAULT_WATER,
  matchingReport,
  type Measure,
  REPORTS,
} from '../scorecard/measures'
import {
  DEFAULT_TABLE_SORT,
  measure,
  type Metric,
  metric,
  minShoreM,
  setMeasure,
  setMetric,
  setMinShoreM,
  setTableSort,
  type TableSort,
  tableSort,
} from './store'

// The URL mirrors the scorecard's state, both ways, like the map's (state/url.ts).
// #/scorecard search params:
//   report=municipal               a preset (REPORTS id); default: the first one
//   count=municipal,county         a custom measure instead of a preset: what counts
//   of=municipal,county,private    ... out of what (default: every category)
//   water=wide,pond                ... on which water (default: wide,narrow)
//   rank=distance                  share (default) | distance | per-1000
//   min_shore=500                  shore floor in meters (unit-independent)
//   sort=name,-type                table sort, `-` for descending (default: -share)
// Defaults are left out, so a fresh visit is just #/scorecard.

const RANK: Record<Metric, string> = { pct: 'share', distance: 'distance', perThousand: 'per-1000' }

function list<T extends string>(s: string | null, allowed: readonly T[]): T[] | null {
  if (s === null) {
    return null
  }
  if (s === 'none') {
    return []
  }
  return allowed.filter((x) => s.split(',').includes(x))
}

/** In canonical (display) order, so the same choice always gives the same URL. */
function formatList<T extends string>(items: T[], order: readonly T[]): string {
  return items.length === 0 ? 'none' : order.filter((x) => items.includes(x)).join(',')
}

function sameSet<T>(a: T[], b: readonly T[]): boolean {
  return a.length === b.length && a.every((x) => b.includes(x))
}

function formatSort(s: TableSort): string {
  return s.map((c) => (c.desc ? `-${c.id}` : c.id)).join(',')
}

function parseSort(s: string | null): TableSort {
  const sort = (s ?? '')
    .split(',')
    .filter(Boolean)
    .map((x) => (x.startsWith('-') ? { id: x.slice(1), desc: true } : { id: x, desc: false }))
  return sort.length > 0 ? sort : DEFAULT_TABLE_SORT
}

export function scorecardParams(): URLSearchParams {
  const q = new URLSearchParams()
  const m = measure()
  const report = matchingReport(m)
  if (report) {
    if (report !== REPORTS[0]) {
      q.set('report', report.id)
    }
  } else {
    q.set('count', formatList(m.numerator, ALL_CATEGORIES))
    if (!sameSet(m.denominator, ALL_CATEGORIES)) {
      q.set('of', formatList(m.denominator, ALL_CATEGORIES))
    }
    if (!sameSet(m.water, DEFAULT_WATER)) {
      q.set('water', formatList(m.water, ALL_WATER))
    }
  }
  if (metric() !== 'pct') {
    q.set('rank', RANK[metric()])
  }
  if (minShoreM() !== DEFAULT_MIN_SHORE_M) {
    q.set('min_shore', String(Math.round(minShoreM())))
  }
  const sort = formatSort(tableSort())
  if (sort !== formatSort(DEFAULT_TABLE_SORT)) {
    q.set('sort', sort)
  }
  return q
}

/** The #/scorecard path for the current state. */
export function scorecardPath(): string {
  // Commas are legal in a query string; keep the lists readable.
  const s = scorecardParams().toString().replaceAll('%2C', ',')
  return s ? `/scorecard?${s}` : '/scorecard'
}

function parseMeasure(q: URLSearchParams): Measure {
  const base = (REPORTS.find((r) => r.id === q.get('report')) ?? REPORTS[0]).measure
  if (!q.has('count')) {
    return base
  }
  const denominator = list<Category>(q.get('of'), ALL_CATEGORIES) ?? ALL_CATEGORIES
  const water = list<WaterKind>(q.get('water'), ALL_WATER) ?? DEFAULT_WATER
  return {
    numerator: (list<Category>(q.get('count'), ALL_CATEGORIES) ?? []).filter((c) =>
      denominator.includes(c),
    ),
    denominator,
    water: water.length > 0 ? water : DEFAULT_WATER,
  }
}

/** Keeps the #/scorecard URL and the store in sync. Render once, inside the router. */
export function ScorecardUrlSync(): null {
  const location = useLocation()
  const navigate = useNavigate()
  // The last URL written here: when the URL is that, it says nothing new (see UrlSync).
  let lastWrite: string | null = null

  // URL -> store. Tracks only the URL.
  createEffect(
    on([() => location.pathname, () => location.search], ([path, search]) => {
      if (path !== '/scorecard') {
        return
      }
      if (lastWrite !== null && decodeURIComponent(path + search) === lastWrite) {
        return
      }
      const q = new URLSearchParams(search)
      const m = parseMeasure(q)
      const cur = measure()
      if (
        !sameSet(m.numerator, cur.numerator) ||
        !sameSet(m.denominator, cur.denominator) ||
        !sameSet(m.water, cur.water)
      ) {
        setMeasure(m)
      }
      const rank = q.get('rank')
      setMetric((Object.keys(RANK) as Metric[]).find((k) => RANK[k] === rank) ?? 'pct')
      const floor = Number(q.get('min_shore') ?? NaN)
      setMinShoreM(Number.isFinite(floor) && floor >= 0 ? floor : DEFAULT_MIN_SHORE_M)
      const sort = parseSort(q.get('sort'))
      if (formatSort(sort) !== formatSort(tableSort())) {
        setTableSort(sort)
      }
    }),
  )

  // Store -> URL, in place (no history entry per click).
  createEffect(() => {
    if (location.pathname !== '/scorecard') {
      return
    }
    const to = scorecardPath()
    if (decodeURIComponent(location.pathname + location.search) !== decodeURIComponent(to)) {
      lastWrite = decodeURIComponent(to)
      navigate(to, { replace: true, scroll: false })
    }
  })

  return null
}
