// Scorecard measures: plain aggregation over the tidy stats.json rows.

import { ALL_CATEGORIES, PUBLIC_ACCESS_CATEGORIES } from '../lib/categories'
import type { Category, Stats, StatsMuni, WaterKind } from '../lib/contract'

/** Default water: lakes, rivers and narrow streams; ponds are opt-in. */
export const DEFAULT_WATER: WaterKind[] = ['wide', 'narrow']
export const ALL_WATER: WaterKind[] = ['wide', 'narrow', 'pond']

export interface Measure {
  /** Shore that counts (the "good" part). Always a subset of `denominator`. */
  numerator: Category[]
  /** Shore it's measured against. */
  denominator: Category[]
  /** Water types counted (numerator and denominator alike). */
  water: WaterKind[]
}

export interface Report {
  id: string
  label: string
  description: string
  measure: Measure
}

export const REPORTS: Report[] = [
  {
    id: 'public',
    label: 'Public access, any provider',
    description:
      'Shore the public can reach from land, whoever provides it: the municipality, county, state, UW, land trusts and other public bodies.',
    measure: {
      numerator: PUBLIC_ACCESS_CATEGORIES,
      denominator: ALL_CATEGORIES,
      water: DEFAULT_WATER,
    },
  },
  {
    id: 'municipal',
    label: 'Provided by the municipality',
    description: 'Shore the municipality itself opens to the public: its own land and street ends.',
    measure: { numerator: ['municipal'], denominator: ALL_CATEGORIES, water: DEFAULT_WATER },
  },
  {
    id: 'public_plus_private',
    label: 'Public access, including private land',
    description:
      'Like "any provider", plus privately owned shore that is open to the public (e.g. the Edgewood campus).',
    measure: {
      numerator: [...PUBLIC_ACCESS_CATEGORIES, 'private_public_access'],
      denominator: ALL_CATEGORIES,
      water: DEFAULT_WATER,
    },
  },
  {
    id: 'public_wide',
    label: 'Public access on lakes & wide rivers',
    description:
      'Public access from any provider, counting only lakes, named ponds and rivers at least 30 m wide.',
    measure: {
      numerator: PUBLIC_ACCESS_CATEGORIES,
      denominator: ALL_CATEGORIES,
      water: ['wide'],
    },
  },
  {
    id: 'public_with_ponds',
    label: 'Public access, including ponds',
    description:
      'Like "any provider", plus ponds the county and DNR don\'t name (often stormwater ponds): credit for ponds ringed by parks, a penalty for ponds behind private lots.',
    measure: {
      numerator: PUBLIC_ACCESS_CATEGORIES,
      denominator: ALL_CATEGORIES,
      water: ALL_WATER,
    },
  },
  {
    id: 'no_access',
    label: 'No public access',
    description: 'Shore with no public access from land: private, plus public land that is closed.',
    measure: {
      numerator: ['private', 'public_no_access'],
      denominator: ALL_CATEGORIES,
      water: DEFAULT_WATER,
    },
  },
]

function sameSet<T>(a: T[], b: T[]): boolean {
  return a.length === b.length && a.every((c) => b.includes(c))
}

/** The preset matching a measure, if any. */
export function matchingReport(m: Measure): Report | undefined {
  return REPORTS.find(
    (r) =>
      sameSet(r.measure.water, m.water) &&
      sameSet(r.measure.numerator, m.numerator) &&
      sameSet(r.measure.denominator, m.denominator),
  )
}

/** Default shore floor: below this much measured shore, one park or street end swings
 * a municipality's share a lot, so it's left out unless the user lowers the floor. */
export const DEFAULT_MIN_SHORE_M = 1000

export interface Score {
  muni: StatsMuni
  numeratorM: number
  denominatorM: number
  /** numerator / denominator; null when there's no shore to measure. */
  pct: number | null
  /** Numerator meters per 1,000 residents. */
  perThousandM: number
}

export function computeScores(stats: Stats, m: Measure): Score[] {
  const byMuni = new Map<number, { num: number; den: number }>()
  for (const muni of stats.municipalities) {
    byMuni.set(muni.muni_id, { num: 0, den: 0 })
  }
  for (const row of stats.shore) {
    const acc = byMuni.get(row.muni_id)
    if (!acc || !m.water.includes(row.water_kind)) {
      continue
    }
    if (m.denominator.includes(row.category)) {
      acc.den += row.length_m
      if (m.numerator.includes(row.category)) {
        acc.num += row.length_m
      }
    }
  }
  return stats.municipalities.map((muni) => {
    const acc = byMuni.get(muni.muni_id) ?? { num: 0, den: 0 }
    return {
      muni,
      numeratorM: acc.num,
      denominatorM: acc.den,
      pct: acc.den > 0 ? acc.num / acc.den : null,
      perThousandM: muni.population > 0 ? (acc.num / muni.population) * 1000 : 0,
    }
  })
}

/** All municipalities together. */
export function totalScore(scores: Score[]): Omit<Score, 'muni'> & {
  population: number
} {
  const t = scores.reduce(
    (a, s) => ({
      num: a.num + s.numeratorM,
      den: a.den + s.denominatorM,
      pop: a.pop + s.muni.population,
    }),
    { num: 0, den: 0, pop: 0 },
  )
  return {
    numeratorM: t.num,
    denominatorM: t.den,
    pct: t.den > 0 ? t.num / t.den : null,
    perThousandM: t.pop > 0 ? (t.num / t.pop) * 1000 : 0,
    population: t.pop,
  }
}
