import { useLocation, useNavigate, useSearchParams } from '@solidjs/router'
import { createEffect, createSignal, on } from 'solid-js'

import {
  type Bbox,
  colorBy,
  focusMuni,
  mapBbox,
  segRequest,
  selected,
  setCameraRequest,
  setColorBy,
  setFocusMuni,
  setSegRequest,
  setSelected,
  setView,
  stats,
  zoomToMuni,
} from './store'

// The URL mirrors the map's state, both ways (hash URLs: GitHub Pages has no SPA
// fallback). Routes: #/map (default) and #/scorecard. Map search params:
//   bbox=-89.3920,43.0580,-89.3840,43.0660   west,south,east,north (WGS84, 4 decimals
//                                            ~ 10 m); the map fits it on load and
//                                            rewrites it as you pan
//   municipality=city-of-madison             focus (slug of the name, stable across
//                                            pipeline runs); zooms to it without bbox
//   seg=3676                                 selected segment
//   color=access                             color by access (default: category)
// Defaults are left out, so a fresh visit is just #/map.
//
// TODO: remove `seg` once the access review is done. Segment ids change on every
// pipeline run, so these links don't last; they're for review lists only.

export interface MapParams {
  bbox?: string
  municipality?: string
  seg?: string
  color?: string
}

export function municipalitySlug(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
}

export function formatBbox(b: Bbox): string {
  return b.map((x) => x.toFixed(4)).join(',')
}

export function parseBbox(s: string | undefined): Bbox | null {
  const v = (s ?? '').split(',').map(Number)
  if (v.length !== 4 || !v.every(Number.isFinite)) {
    return null
  }
  const [w, south, e, n] = v as Bbox
  return w < e && south < n ? [w, south, e, n] : null
}

/** The map params for the current state (defaults left out). */
export function currentMapParams(): MapParams {
  const b = mapBbox()
  const muni = stats()?.municipalities.find((m) => m.muni_id === focusMuni())
  const seg = selected()?.segment_id ?? segRequest()
  return {
    bbox: b ? formatBbox(b) : undefined,
    municipality: muni ? municipalitySlug(muni.name) : undefined,
    seg: seg === null ? undefined : String(seg),
    color: colorBy() === 'access' ? 'access' : undefined,
  }
}

/** A #/map path: the current state, with `overrides` (undefined drops a param). */
export function mapPath(overrides: Partial<MapParams> = {}): string {
  const p = { ...currentMapParams(), ...overrides }
  const q = new URLSearchParams()
  for (const [k, v] of Object.entries(p)) {
    if (v) {
      q.set(k, v)
    }
  }
  // Commas are legal in a query string; keep the bbox readable.
  const s = q.toString().replaceAll('%2C', ',')
  return s ? `/map?${s}` : '/map'
}

/** Keeps the URL and the store in sync. Render once, inside the router. */
export function UrlSync(): null {
  const location = useLocation()
  const navigate = useNavigate()
  const [params] = useSearchParams<{ [K in keyof MapParams]: string }>()
  // Set once the URL has been applied with stats loaded (municipality slugs need
  // them). Until then the store mustn't write back, or it would wipe params it hasn't
  // read yet.
  const [applied, setApplied] = createSignal(false)
  // The last URL this component wrote. When the URL is that, it says nothing new: during
  // a router transition the params can lag a step behind, and re-applying them made the
  // map and the URL chase each other (100 navigations, "Too many redirects").
  let lastWrite: string | null = null

  createEffect(() => {
    const path = location.pathname
    setView(
      path.startsWith('/scorecard') ? 'scorecard' : path.startsWith('/about') ? 'about' : 'map',
    )
  })

  // URL -> store. `on` tracks only the URL (and stats arriving); the store is read
  // untracked, so a store change never re-applies the URL.
  createEffect(
    on([() => location.pathname, () => location.search, stats], ([path, , s]) => {
      if (path.startsWith('/scorecard')) {
        return
      }
      if (lastWrite !== null && decodeURIComponent(path + location.search) === lastWrite) {
        return
      }
      const color = params.color === 'access' ? 'access' : 'category'
      if (color !== colorBy()) {
        setColorBy(color)
      }

      const bbox = parseBbox(params.bbox)
      const current = mapBbox()
      if (bbox && (current === null || params.bbox !== formatBbox(current))) {
        setCameraRequest({ bbox, padding: 0, animate: false })
      }

      const seg = Number(params.seg)
      if (params.seg && Number.isInteger(seg)) {
        if (seg !== selected()?.segment_id) {
          setSegRequest(seg)
        }
      } else if (selected() !== null || segRequest() !== null) {
        setSelected(null)
        setSegRequest(null)
      }

      if (!s) {
        return
      }
      const muni = params.municipality
        ? s.municipalities.find((m) => municipalitySlug(m.name) === params.municipality)
        : undefined
      const id = muni?.muni_id ?? null
      if (id !== focusMuni()) {
        setFocusMuni(id)
        if (!bbox) {
          zoomToMuni(id)
        }
      }
      setApplied(true)
    }),
  )

  // Store -> URL, in place (no history entry per pan).
  createEffect(() => {
    if (!applied() || location.pathname !== '/map' || mapBbox() === null) {
      return
    }
    const next = currentMapParams()
    const keys = Object.keys(next) as (keyof MapParams)[]
    if (keys.some((k) => next[k] !== params[k])) {
      // In place: no history entry per pan. Our own serializer, so commas stay commas.
      const to = mapPath()
      lastWrite = decodeURIComponent(to)
      navigate(to, { replace: true, scroll: false })
    }
  })

  return null
}
