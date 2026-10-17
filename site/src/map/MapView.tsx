import 'maplibre-gl/dist/maplibre-gl.css'

import { layers, namedFlavor } from '@protomaps/basemaps'
import {
  addProtocol,
  AttributionControl,
  type ExpressionSpecification,
  type FilterSpecification,
  Map as MlMap,
  NavigationControl,
  setWorkerUrl,
} from 'maplibre-gl'
// MapLibre finds its worker as a sibling file of its own module, which no longer holds
// once a bundler moves the module. Let Vite bundle the worker and pass its URL instead.
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url'
import { PMTiles, Protocol } from 'pmtiles'
import {
  createEffect,
  getOwner,
  type JSX,
  onCleanup,
  onMount,
  runWithOwner,
  untrack,
} from 'solid-js'

import {
  MUNI_LABELS_LAYER,
  MUNIS_LAYER,
  PARKS_LAYER,
  SHORE_ALT_LAYER,
  SHORE_LAYER,
  type ShoreProps,
} from '../lib/contract'
import {
  colorBy,
  focusMuni,
  scores,
  selected,
  setHasAlt,
  setSelected,
  shadeMunis,
  showAlt,
  showMunis,
  stats,
  view,
} from '../state/store'
import { accessColorExpr, categoryColorExpr, type Mode, muniFillExpr } from './colors'

function dataUrl(file: string): string {
  return new URL(`${import.meta.env.BASE_URL}data/${file}`, window.location.href).href
}

// One protocol for the whole app: MapLibre fetches pmtiles:// URLs through it, using
// HTTP range requests against the static files (no tile server).
setWorkerUrl(workerUrl)

const protocol = new Protocol()
addProtocol('pmtiles', protocol.tile)

const SHORE_IDS = ['shore', 'shore-alt'] as const

export default function MapView(): JSX.Element {
  let container: HTMLDivElement | undefined
  let map: MlMap | undefined
  const mode: Mode = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
  const surface = mode === 'dark' ? '#1a1a19' : '#fcfcfb'

  onMount(() => {
    if (!container) {
      throw new Error('map container not mounted')
    }
    // The map's load handler runs later, outside Solid's tracking scope; keep the
    // component's owner so effects created there are disposed with the component.
    const owner = getOwner()
    const shore = new PMTiles(dataUrl('shore.pmtiles'))
    const basemap = new PMTiles(dataUrl('basemap.pmtiles'))
    protocol.add(shore)
    protocol.add(basemap)
    const flavor = mode === 'dark' ? 'dark' : 'light'

    const m = new MlMap({
      container,
      center: [-89.415, 43.055],
      zoom: 14,
      attributionControl: false,
      style: {
        version: 8,
        glyphs: 'https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf',
        sprite: `https://protomaps.github.io/basemaps-assets/sprites/v4/${flavor}`,
        sources: {
          protomaps: {
            type: 'vector',
            url: `pmtiles://${basemap.source.getKey()}`,
            attribution:
              '<a href="https://protomaps.com">Protomaps</a> © <a href="https://openstreetmap.org/copyright">OpenStreetMap</a>',
          },
          // County-wide reference layers (municipal boundaries); attribution as above.
          context: { type: 'vector', url: `pmtiles://${dataUrl('context.pmtiles')}` },
          shore: {
            type: 'vector',
            url: `pmtiles://${shore.source.getKey()}`,
            attribution: 'Dane County LIO · WI DNR · WI Statewide Parcel Map (SCO V12)',
          },
        },
        layers: layers('protomaps', namedFlavor(flavor), { lang: 'en' }),
      },
    })
    map = m
    m.addControl(new AttributionControl({ compact: true }))
    m.addControl(new NavigationControl({ showCompass: false }), 'top-right')

    // The load handler is sync; its async work reports failures instead of leaving an
    // unhandled rejection that MapLibre would never see.
    m.on('load', () => {
      addOverlays().catch((e: unknown) => {
        console.error('Failed to add shore layers', e)
      })
    })

    async function addOverlays(): Promise<void> {
      m.addLayer({
        id: 'parks',
        type: 'line',
        source: 'shore',
        'source-layer': PARKS_LAYER,
        paint: {
          'line-color': mode === 'dark' ? '#c3c2b7' : '#52514e',
          'line-width': 1,
          'line-dasharray': [2, 2],
          'line-opacity': 0.6,
        },
      })

      // Municipalities shaded by the current scorecard measure (under everything else).
      m.addLayer(
        {
          id: 'muni-fill',
          type: 'fill',
          source: 'context',
          'source-layer': MUNIS_LAYER,
          layout: { visibility: 'none' },
          paint: { 'fill-color': 'rgba(0,0,0,0)', 'fill-opacity': 0.55 },
        },
        'parks',
      )

      const muniInk = mode === 'dark' ? '#c3c2b7' : '#52514e'
      m.addLayer({
        id: 'munis',
        type: 'line',
        source: 'context',
        'source-layer': MUNIS_LAYER,
        layout: { visibility: 'none', 'line-join': 'round' },
        paint: { 'line-color': muniInk, 'line-width': 1.5, 'line-dasharray': [4, 2] },
      })
      // Outline of the focused municipality.
      m.addLayer({
        id: 'muni-focus',
        type: 'line',
        source: 'context',
        'source-layer': MUNIS_LAYER,
        filter: ['==', ['get', 'muni_id'], -1],
        layout: { 'line-join': 'round' },
        paint: { 'line-color': muniInk, 'line-width': 2.5 },
      })

      const meta = (await shore.getMetadata()) as { vector_layers?: { id: string }[] }
      const alt = !!meta.vector_layers?.some((l) => l.id === SHORE_ALT_LAYER)
      setHasAlt(alt)

      for (const [id, sourceLayer] of [
        ['shore', SHORE_LAYER],
        ['shore-alt', SHORE_ALT_LAYER],
      ] as const) {
        if (id === 'shore-alt' && !alt) {
          continue
        }
        const visibility = id === 'shore' ? 'visible' : 'none'
        // Surface-colored casing keeps the colored line legible over any basemap color.
        m.addLayer({
          id: `${id}-casing`,
          type: 'line',
          source: 'shore',
          'source-layer': sourceLayer,
          layout: { 'line-cap': 'round', 'line-join': 'round', visibility },
          paint: {
            'line-color': surface,
            'line-width': ['interpolate', ['linear'], ['zoom'], 10, 6, 16, 18],
          },
        })
        m.addLayer({
          id,
          type: 'line',
          source: 'shore',
          'source-layer': sourceLayer,
          layout: { 'line-cap': 'round', 'line-join': 'round', visibility },
          paint: {
            'line-color': categoryColorExpr(mode),
            'line-width': ['interpolate', ['linear'], ['zoom'], 10, 3, 16, 10],
          },
        })
        // Invisible wide line: a click target bigger than the mark.
        m.addLayer({
          id: `${id}-hit`,
          type: 'line',
          source: 'shore',
          'source-layer': sourceLayer,
          layout: { visibility },
          paint: { 'line-color': '#000', 'line-opacity': 0, 'line-width': 24 },
        })
        m.on('click', `${id}-hit`, (e) => {
          const props = e.features?.[0]?.properties
          setSelected(props ? (props as ShoreProps) : null)
        })
        m.on('mouseenter', `${id}-hit`, () => (m.getCanvas().style.cursor = 'pointer'))
        m.on('mouseleave', `${id}-hit`, () => (m.getCanvas().style.cursor = ''))
      }
      m.addLayer({
        id: 'selected',
        type: 'line',
        source: 'shore',
        'source-layer': SHORE_LAYER,
        filter: ['==', ['get', 'segment_id'], -1],
        layout: { 'line-cap': 'round' },
        paint: {
          'line-color': mode === 'dark' ? '#f0efec' : '#0b0b0b',
          'line-width': 2,
          // Outline just outside the shore line, at every zoom.
          'line-gap-width': ['interpolate', ['linear'], ['zoom'], 10, 4, 16, 12],
        },
      })

      m.addLayer({
        id: 'muni-labels',
        type: 'symbol',
        source: 'context',
        'source-layer': MUNI_LABELS_LAYER,
        layout: {
          visibility: 'none',
          'text-field': ['get', 'name'],
          'text-font': ['Noto Sans Medium'],
          'text-size': 13,
        },
        paint: {
          'text-color': muniInk,
          'text-halo-color': surface,
          'text-halo-width': 1.5,
        },
      })

      // The basemap is an extract: low-zoom tiles cover far more than the study area, and
      // beyond the extract there's nothing. Keep the camera inside the extract's bounds;
      // MapLibre then also stops zooming out once the view would exceed them.
      const b = await basemap.getHeader()
      m.setMaxBounds([
        [b.minLon, b.minLat],
        [b.maxLon, b.maxLat],
      ])

      const h = await shore.getHeader()
      m.fitBounds(
        [
          [h.minLon, h.minLat],
          [h.maxLon, h.maxLat],
        ],
        { padding: 40, duration: 0 },
      )

      // Signals -> map, in place.
      runWithOwner(owner, () => {
        bindSignals(m, alt)
      })
    }
  })

  function bindSignals(m: MlMap, alt: boolean): void {
    createEffect(() => {
      const expr = colorBy() === 'category' ? categoryColorExpr(mode) : accessColorExpr()
      for (const id of SHORE_IDS) {
        if (m.getLayer(id)) {
          m.setPaintProperty(id, 'line-color', expr)
        }
      }
    })
    createEffect(() => {
      const useAlt = showAlt() && alt
      for (const [id, on] of [
        ['shore', !useAlt],
        ['shore-alt', useAlt],
      ] as const) {
        for (const suffix of ['-casing', '', '-hit']) {
          if (m.getLayer(id + suffix)) {
            m.setLayoutProperty(id + suffix, 'visibility', on ? 'visible' : 'none')
          }
        }
      }
      m.setLayoutProperty('selected', 'visibility', useAlt ? 'none' : 'visible')
      setSelected(null)
    })
    createEffect(() => {
      const visibility = showMunis() ? 'visible' : 'none'
      m.setLayoutProperty('munis', 'visibility', visibility)
      m.setLayoutProperty('muni-labels', 'visibility', visibility)
    })
    createEffect(() => {
      // Focus on one municipality: fade the other shore, click only its own, zoom to it.
      const id = focusMuni()
      const muni = stats()?.municipalities.find((x) => x.muni_id === id) ?? null
      const name = muni?.name ?? null
      const opacity: ExpressionSpecification | number =
        name === null ? 1 : ['case', ['==', ['get', 'muni_name'], name], 1, 0.15]
      const hitFilter: FilterSpecification | null =
        name === null ? null : ['==', ['get', 'muni_name'], name]
      for (const id of SHORE_IDS) {
        if (m.getLayer(id)) {
          m.setPaintProperty(id, 'line-opacity', opacity)
          m.setPaintProperty(`${id}-casing`, 'line-opacity', opacity)
          m.setFilter(`${id}-hit`, hitFilter)
        }
      }
      m.setFilter('muni-focus', ['==', ['get', 'muni_id'], muni?.muni_id ?? -1])
      // untrack: picking a segment mustn't re-run this effect (and re-zoom).
      const sel = untrack(selected)
      if (name !== null && sel && sel.muni_name !== name) {
        setSelected(null)
      }
      if (muni?.shore_bbox) {
        const [w, s, e, n] = muni.shore_bbox
        m.fitBounds(
          [
            [w, s],
            [e, n],
          ],
          { padding: 60, maxZoom: 15 },
        )
      }
    })
    createEffect(() => {
      const on = shadeMunis()
      m.setLayoutProperty('muni-fill', 'visibility', on ? 'visible' : 'none')
      if (on) {
        const values = scores().flatMap((s): [number, number][] =>
          s.pct === null ? [] : [[s.muni.muni_id, s.pct]],
        )
        m.setPaintProperty('muni-fill', 'fill-color', muniFillExpr(values))
      }
    })
    createEffect(() => {
      // The map is hidden (display: none) on the scorecard tab; resize when it's back.
      if (view() === 'map') {
        m.resize()
      }
    })
    createEffect(() => {
      m.setFilter('selected', ['==', ['get', 'segment_id'], selected()?.segment_id ?? -1])
    })
  }

  onCleanup(() => map?.remove())

  return <div ref={(el) => (container = el)} class="map" />
}
