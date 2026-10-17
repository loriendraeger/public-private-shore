import type { ExpressionSpecification } from 'maplibre-gl'

import type { Access, OwnerClass } from '../lib/contract'

export type Mode = 'light' | 'dark'

// Ownership: 11 classes fold into 4 groups. A map is an "all pairs" view (any color can
// sit next to any other), where only three categorical hues stay distinguishable for
// color-blind readers. The exact class and owner label show in the segment panel.
// Palette validated with the dataviz validator (--pairs all), light and dark.
export type OwnerGroup = 'public' | 'private' | 'row' | 'other'

export const OWNER_GROUP: Record<OwnerClass, OwnerGroup> = {
  federal: 'public',
  state: 'public',
  county: 'public',
  municipal: 'public',
  university: 'public',
  school_district: 'public',
  other_public: 'public',
  private: 'private',
  row: 'row',
  utility: 'other',
  unknown: 'other',
}

// Records keyed by the union types, so every lookup is total (no `undefined` to handle).
// Key order is the legend order.
export const OWNER_GROUPS: Record<OwnerGroup, { label: string; color: Record<Mode, string> }> = {
  public: { label: 'Public', color: { light: '#2a78d6', dark: '#3987e5' } },
  private: { label: 'Private', color: { light: '#eb6834', dark: '#d95926' } },
  row: { label: 'Road right-of-way', color: { light: '#1baf7a', dark: '#199e70' } },
  other: { label: 'Utility / unknown', color: { light: '#898781', dark: '#898781' } },
}

// Access is a state, so it uses the status palette, always with an icon + label.
export const ACCESS: Record<Access, { label: string; icon: string; color: string }> = {
  open: { label: 'Open to the public', icon: '✓', color: '#0ca30c' },
  restricted: { label: 'Restricted (fees, hours, members)', icon: '◐', color: '#fab219' },
  none: { label: 'No access from land', icon: '✕', color: '#d03b3b' },
  unknown: { label: 'Unknown', icon: '?', color: '#898781' },
}

/** `Object.entries` with the key type kept (it widens keys to `string`). */
export function entries<K extends string, V>(record: Record<K, V>): [K, V][] {
  return Object.entries(record) as [K, V][]
}

export function ownerColorExpr(mode: Mode): ExpressionSpecification {
  const byClass = entries(OWNER_GROUP).flatMap(([cls, group]) => [
    cls,
    OWNER_GROUPS[group].color[mode],
  ])
  return [
    'match',
    ['get', 'owner_class'],
    ...byClass,
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
