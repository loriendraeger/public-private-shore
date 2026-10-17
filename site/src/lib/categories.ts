import type { Category } from './contract'

export interface CategoryInfo {
  label: string
  /** Counted as public access in the default reports. */
  publicAccess: boolean
  description: string
}

// Key order is display order. `unknown` is listed but excluded from the scorecard
// until the unknowns are cleaned up.
export const CATEGORIES: Record<Category, CategoryInfo> = {
  municipal: {
    label: 'Municipal',
    publicAccess: true,
    description: 'Owned by the municipality and open to the public, plus street ends',
  },
  county: { label: 'County', publicAccess: true, description: 'Dane County, open' },
  state_federal: {
    label: 'State & federal',
    publicAccess: true,
    description: 'DNR, WisDOT, US Fish & Wildlife and other state or federal land, open',
  },
  university: { label: 'UW–Madison', publicAccess: true, description: 'UW–Madison land, open' },
  land_trust: {
    label: 'Land trust',
    publicAccess: true,
    description: 'Conservation land trust preserves (private nonprofits), open',
  },
  other_public: {
    label: 'Other public',
    publicAccess: true,
    description: 'Sewerage, sanitary and lake districts, open',
  },
  private_public_access: {
    label: 'Private, public access',
    publicAccess: false,
    description: 'Privately owned, but the public can reach the water (e.g. Edgewood campus)',
  },
  public_no_access: {
    label: 'Public, no access',
    publicAccess: false,
    description: 'Publicly owned but not open: schools, facilities, barriers',
  },
  private: { label: 'Private', publicAccess: false, description: 'Privately owned, no access' },
  unknown: {
    label: 'Unknown',
    publicAccess: false,
    description: 'Owner or access not yet determined (excluded for now)',
  },
}

/** Categories the scorecard uses: everything but `unknown`. */
export const KNOWN_CATEGORIES = (Object.keys(CATEGORIES) as Category[]).filter(
  (c) => c !== 'unknown',
)

export const PUBLIC_ACCESS_CATEGORIES = KNOWN_CATEGORIES.filter((c) => CATEGORIES[c].publicAccess)
