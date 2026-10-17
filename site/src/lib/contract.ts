// The frontend half of the data contract with the pipeline.
// Must match pipeline/sql/30_export/*.sql (tile layers + attributes). Change together.

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
  | 'private'
  | 'row'
  | 'unknown'

export type Access = 'open' | 'restricted' | 'none' | 'unknown'

export type AccessSource = 'default' | 'osm' | 'street_end' | 'override'

/** Properties of a feature in the `shore` (and `shore_alt`) tile layer. */
export interface ShoreProps {
  segment_id: number
  waterbody: string
  owner_class: OwnerClass
  owner_label: string
  access: Access
  access_source: AccessSource
  access_note?: string
  muni_name: string
  muni_type: 'city' | 'village' | 'town'
  length_m: number
}
