import type { ExpressionSpecification } from 'maplibre-gl'

import type { Access, Category } from '../lib/contract'

export type Mode = 'light' | 'dark'

// Categories fold into 3 groups on the map. A map is an "all pairs" view (any color can
// sit next to any other), where only three categorical hues stay distinguishable for
// color-blind readers. The exact category and owner show in the segment panel.
// Palette validated with the dataviz validator (--pairs all), light and dark.
export type CategoryGroup = 'municipal' | 'other_access' | 'no_access'

export const CATEGORY_GROUP: Record<Category, CategoryGroup> = {
  municipal: 'municipal',
  county: 'other_access',
  state_federal: 'other_access',
  university: 'other_access',
  land_trust: 'other_access',
  other_public: 'other_access',
  private_public_access: 'other_access',
  public_no_access: 'no_access',
  private: 'no_access',
}

// Records keyed by the union types, so every lookup is total (no `undefined` to handle).
// Key order is the legend order.
export const CATEGORY_GROUPS: Record<
  CategoryGroup,
  { label: string; color: Record<Mode, string> }
> = {
  municipal: {
    label: 'Public access: municipality',
    color: { light: '#2a78d6', dark: '#3987e5' },
  },
  other_access: {
    label: 'Public access: other provider',
    color: { light: '#1baf7a', dark: '#199e70' },
  },
  no_access: { label: 'No public access', color: { light: '#eb6834', dark: '#d95926' } },
}

// Access is a state, so it uses the status palette, always with an icon + label.
export const ACCESS: Record<Access, { label: string; icon: string; color: string }> = {
  open: { label: 'Open to the public', icon: '✓', color: '#0ca30c' },
  none: { label: 'No access from land', icon: '✕', color: '#d03b3b' },
}

// Municipality shading: sequential blue ramp (dataviz reference palette, 100 -> 700),
// light = low share, dark = high.
export const SEQUENTIAL = ['#cde2fb', '#86b6ef', '#3987e5', '#1c5cab', '#0d366b']

/** `Object.entries` with the key type kept (it widens keys to `string`). */
export function entries<K extends string, V>(record: Record<K, V>): [K, V][] {
  return Object.entries(record) as [K, V][]
}

export function categoryColorExpr(mode: Mode): ExpressionSpecification {
  const byCategory = entries(CATEGORY_GROUP).flatMap(([cat, group]) => [
    cat,
    CATEGORY_GROUPS[group].color[mode],
  ])
  return [
    'match',
    ['get', 'category'],
    ...byCategory,
    '#898781',
  ] as unknown as ExpressionSpecification
}

export function accessColorExpr(): ExpressionSpecification {
  return [
    'match',
    ['get', 'access'],
    ...entries(ACCESS).flatMap(([id, a]) => [id, a.color]),
    '#898781',
  ] as unknown as ExpressionSpecification
}

/** Color for a 0..1 share on the sequential ramp (stepped into 5 classes). */
export function sequentialColor(p: number): string {
  const i = Math.min(SEQUENTIAL.length - 1, Math.floor(p * SEQUENTIAL.length))
  return SEQUENTIAL[i] ?? '#898781'
}

/** MapLibre fill color by muni_id: each scored municipality gets its class color. */
export function muniFillExpr(values: [number, number][]): ExpressionSpecification {
  if (values.length === 0) {
    return 'rgba(0,0,0,0)' as unknown as ExpressionSpecification
  }
  return [
    'match',
    ['get', 'muni_id'],
    ...values.flatMap(([id, p]) => [id, sequentialColor(p)]),
    'rgba(0,0,0,0)',
  ] as unknown as ExpressionSpecification
}
