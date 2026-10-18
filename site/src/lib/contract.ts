// The frontend half of the data contract with the pipeline.
// Must match pipeline/sql/30_export/*.sql (tile layers + attributes) and
// pipeline/src/shore/stats.py (stats.json). Change together.

export const SHORE_LAYER = 'shore'
export const SHORE_ALT_LAYER = 'shore_alt' // only present after `make compare`
export const PARKS_LAYER = 'parks'

// context.pmtiles: county-wide reference layers (pipeline/sql/30_export/30_municipalities.sql)
export const MUNIS_LAYER = 'municipalities'
export const MUNI_LABELS_LAYER = 'municipality_labels'

export type OwnerClass =
  | 'federal'
  | 'state'
  | 'county'
  | 'municipal'
  | 'university'
  | 'school_district'
  | 'utility'
  | 'other_public'
  | 'land_trust'
  | 'private'
  | 'row'
  | 'unknown'

export type Access = 'open' | 'none' | 'unknown'

export type AccessSource = 'default' | 'osm' | 'path' | 'street_end' | 'barrier' | 'override'

/** Scorecard category (config/categories.csv): the one attribute the analysis uses. */
export type Category =
  | 'municipal'
  | 'county'
  | 'state_federal'
  | 'university'
  | 'land_trust'
  | 'other_public'
  | 'private_public_access'
  | 'public_no_access'
  | 'private'
  | 'unknown'

export type MuniType = 'city' | 'village' | 'town'

/** Properties of a feature in the `shore` (and `shore_alt`) tile layer. */
export interface ShoreProps {
  segment_id: number
  /** bank: shore of lakes and wide rivers. stream: the centerline of narrow water,
   * standing in for both banks (access if either bank has it). */
  kind: 'bank' | 'stream'
  /** Narrower than the pipeline's narrow_width_m. A narrow `bank` had no centerline. */
  narrow: boolean
  /** named: lakes, rivers, named ponds. pond: water the county and DNR don't name. */
  water_class: 'named' | 'pond'
  waterbody: string
  category: Category
  owner_class: OwnerClass
  owner_label: string
  /** stream only: the owner label of the bank that didn't win, if any. */
  other_bank_label?: string
  access: Access
  access_source: AccessSource
  /** Display text from config/access_display.csv, e.g. "Open to the public", "None". */
  access_label: string
  /** Why, e.g. "Park: Olin Park", "Public path"; absent when there's nothing to add. */
  access_reason?: string
  muni_name: string
  muni_type: MuniType
  length_m: number
}

/** stats.json: tidy rows, lengths in meters. The site aggregates. */
export interface Stats {
  generated: string
  sources: Record<string, { name: string; retrieved: string }>
  municipalities: StatsMuni[]
  shore: StatsShoreRow[]
}

export interface StatsMuni {
  muni_id: number
  name: string
  muni_type: MuniType
  /** WI DOA final estimate (Dane County part), 1/1/2026 */
  population: number
  pop_census_2020: number
  /** [west, south, east, north] of its shore (EPSG:4326); null when it has none. */
  shore_bbox: [number, number, number, number] | null
}

/** wide: lakes and wide rivers. narrow: narrower than 30 m, counted once (centerline).
 * pond: standalone water the county and DNR don't name (at least 1 ha). */
export type WaterKind = 'wide' | 'narrow' | 'pond'

export interface StatsShoreRow {
  muni_id: number
  waterbody: string
  water_kind: WaterKind
  category: Category
  length_m: number
}
