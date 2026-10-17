// Scorecard measures: plain aggregation over the tidy stats.json rows.

import { KNOWN_CATEGORIES, PUBLIC_ACCESS_CATEGORIES } from '../lib/categories'
import type { Category, Stats, StatsMuni, WaterKind } from '../lib/contract'

export type WaterFilter = 'all' | WaterKind

export interface Measure {
  /** Shore that counts (the "good" part). Always a subset of `denominator`. */
  numerator: Category[]
  /** Shore it's measured against. */
  denominator: Category[]
  water: WaterFilter
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
    measure: { numerator: PUBLIC_ACCESS_CATEGORIES, denominator: KNOWN_CATEGORIES, water: 'all' },
  },
  {
    id: 'municipal',
    label: 'Provided by the municipality',
    description: 'Shore the municipality itself opens to the public: its own land and street ends.',
    measure: { numerator: ['municipal'], denominator: KNOWN_CATEGORIES, water: 'all' },
  },
  {
    id: 'public_plus_private',
    label: 'Public access, including private land',
    description:
      'Like "any provider", plus privately owned shore that is open to the public (e.g. the Edgewood campus).',
    measure: {
      numerator: [...PUBLIC_ACCESS_CATEGORIES, 'private_public_access'],
      denominator: KNOWN_CATEGORIES,
      water: 'all',
    },
  },
  {
    id: 'public_lakes',
    label: 'Public access on lakes',
    description: 'Public access from any provider, counting lake and pond shore only (no rivers).',
    measure: { numerator: PUBLIC_ACCESS_CATEGORIES, denominator: KNOWN_CATEGORIES, water: 'lake' },
  },
  {
    id: 'no_access',
    label: 'No public access',
    description: 'Shore with no public access from land: private, plus public land that is closed.',
    measure: {
      numerator: ['private', 'public_no_access'],
      denominator: KNOWN_CATEGORIES,
      water: 'all',
    },
  },
]

function sameSet(a: Category[], b: Category[]): boolean {
  return a.length === b.length && a.every((c) => b.includes(c))
}

/** The preset matching a measure, if any. */
export function matchingReport(m: Measure): Report | undefined {
  return REPORTS.find(
    (r) =>
      r.measure.water === m.water &&
      sameSet(r.measure.numerator, m.numerator) &&
      sameSet(r.measure.denominator, m.denominator),
  )
}

/** Below this much (measured) shore, a municipality's percentages are flagged as fragile. */
export const LITTLE_SHORE_M = 1000

export interface Score {
  muni: StatsMuni
  numeratorM: number
  denominatorM: number
  /** numerator / denominator; null when there's no shore to measure. */
  pct: number | null
  /** Numerator meters per 1,000 residents. */
  perThousandM: number
  /** Unknown shore left out of the measure (same water filter). */
  unknownM: number
  littleShore: boolean
}

export function computeScores(stats: Stats, m: Measure): Score[] {
  const byMuni = new Map<number, { num: number; den: number; unk: number }>()
  for (const muni of stats.municipalities) {
    byMuni.set(muni.muni_id, { num: 0, den: 0, unk: 0 })
  }
  for (const row of stats.shore) {
    const acc = byMuni.get(row.muni_id)
    if (!acc || (m.water !== 'all' && row.water_kind !== m.water)) {
      continue
    }
    if (row.category === 'unknown') {
      acc.unk += row.length_m
    }
    if (m.denominator.includes(row.category)) {
      acc.den += row.length_m
      if (m.numerator.includes(row.category)) {
        acc.num += row.length_m
      }
    }
  }
  return stats.municipalities.map((muni) => {
    const acc = byMuni.get(muni.muni_id) ?? { num: 0, den: 0, unk: 0 }
    return {
      muni,
      numeratorM: acc.num,
      denominatorM: acc.den,
      pct: acc.den > 0 ? acc.num / acc.den : null,
      perThousandM: muni.population > 0 ? (acc.num / muni.population) * 1000 : 0,
      unknownM: acc.unk,
      littleShore: acc.den < LITTLE_SHORE_M,
    }
  })
}

/** All municipalities together. */
export function totalScore(scores: Score[]): Omit<Score, 'muni' | 'littleShore'> & {
  population: number
} {
  const t = scores.reduce(
    (a, s) => ({
      num: a.num + s.numeratorM,
      den: a.den + s.denominatorM,
      unk: a.unk + s.unknownM,
      pop: a.pop + s.muni.population,
    }),
    { num: 0, den: 0, unk: 0, pop: 0 },
  )
  return {
    numeratorM: t.num,
    denominatorM: t.den,
    pct: t.den > 0 ? t.num / t.den : null,
    perThousandM: t.pop > 0 ? (t.num / t.pop) * 1000 : 0,
    unknownM: t.unk,
    population: t.pop,
  }
}
