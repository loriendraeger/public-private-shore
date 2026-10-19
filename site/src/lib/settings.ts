// Pipeline settings quoted in the site's text, from stats.json (config/pipeline.toml),
// formatted in the display unit. Empty until stats.json has loaded.

import { stats, units } from '../state/store'
import { formatArea, formatShort } from './units'

/** Below this width, water collapses onto its centerline and counts once, e.g. "30 m". */
export function narrowWidth(): string {
  const s = stats()
  return s ? formatShort(s.settings.narrow_width_m, units()) : ''
}

/** How far behind the shore its parcel may be, e.g. "15 m". */
export function snapTolerance(): string {
  const s = stats()
  return s ? formatShort(s.settings.snap_tolerance_m, units()) : ''
}

/** Smallest unnamed pond in scope, e.g. "1 ha". */
export function pondMinArea(): string {
  const s = stats()
  return s ? formatArea(s.settings.pond_min_area_m2, units()) : ''
}
