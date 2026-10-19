// All data is in meters; units only change what's displayed.

export type Units = 'metric' | 'imperial'

const FT_PER_M = 3.28084
const M_PER_MI = 1609.344

/** Long distances (shore totals): km or mi. */
export function formatLong(m: number, units: Units): string {
  const v = units === 'metric' ? m / 1000 : m / M_PER_MI
  return `${v.toLocaleString(undefined, { maximumFractionDigits: v < 10 ? 2 : 1 })} ${units === 'metric' ? 'km' : 'mi'}`
}

/** Short distances (segments, per-capita): m or ft. */
export function formatShort(m: number, units: Units): string {
  const v = units === 'metric' ? m : m * FT_PER_M
  return `${Math.round(v).toLocaleString()} ${units === 'metric' ? 'm' : 'ft'}`
}

/** A long distance as a number in the display unit (for charts). */
export function toLong(m: number, units: Units): number {
  return units === 'metric' ? m / 1000 : m / M_PER_MI
}

/** Inverse of toLong: a long distance in the display unit back to meters. */
export function fromLong(v: number, units: Units): number {
  return units === 'metric' ? v * 1000 : v * M_PER_MI
}

export function toShort(m: number, units: Units): number {
  return units === 'metric' ? m : m * FT_PER_M
}

export function longUnit(units: Units): string {
  return units === 'metric' ? 'km' : 'mi'
}

export function shortUnit(units: Units): string {
  return units === 'metric' ? 'm' : 'ft'
}

export function formatPct(p: number): string {
  return `${(p * 100).toLocaleString(undefined, { maximumFractionDigits: p < 0.1 ? 1 : 0 })}%`
}

const M2_PER_ACRE = 4046.856

/** Areas (pond size): ha or acres. */
export function formatArea(m2: number, units: Units): string {
  const v = units === 'metric' ? m2 / 10_000 : m2 / M2_PER_ACRE
  return `${v.toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units === 'metric' ? 'ha' : v === 1 ? 'acre' : 'acres'}`
}
