import 'maplibre-gl/dist/maplibre-gl.css'

import { layers, namedFlavor } from '@protomaps/basemaps'
import {
  addProtocol,
  AttributionControl,
  Map as MlMap,
  NavigationControl,
  setWorkerUrl,
} from 'maplibre-gl'
// MapLibre finds its worker as a sibling file of its own module, which no longer holds
// once a bundler moves the module. Let Vite bundle the worker and pass its URL instead.
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url'
import { PMTiles, Protocol } from 'pmtiles'
import { createEffect, getOwner, type JSX, onCleanup, onMount, runWithOwner } from 'solid-js'

import { PARKS_LAYER, SHORE_ALT_LAYER, SHORE_LAYER, type ShoreProps } from '../lib/contract'
import { colorBy, selected, setHasAlt, setSelected, showAlt } from '../state/store'
import { accessColorExpr, type Mode, ownerColorExpr } from './colors'

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
    protocol.add(shore)
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
            url: `pmtiles://${dataUrl('basemap.pmtiles')}`,
            attribution:
              '<a href="https://protomaps.com">Protomaps</a> © <a href="https://openstreetmap.org/copyright">OpenStreetMap</a>',
          },
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
            'line-width': ['interpolate', ['linear'], ['zoom'], 10, 3, 16, 9],
          },
        })
        m.addLayer({
          id,
          type: 'line',
          source: 'shore',
          'source-layer': sourceLayer,
          layout: { 'line-cap': 'round', 'line-join': 'round', visibility },
          paint: {
            'line-color': ownerColorExpr(mode),
            'line-width': ['interpolate', ['linear'], ['zoom'], 10, 1.5, 16, 5],
          },
        })
        // Invisible wide line: a click target bigger than the mark.
        m.addLayer({
          id: `${id}-hit`,
          type: 'line',
          source: 'shore',
          'source-layer': sourceLayer,
          layout: { visibility },
          paint: { 'line-color': '#000', 'line-opacity': 0, 'line-width': 18 },
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
          'line-gap-width': 6,
        },
      })

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
      const expr = colorBy() === 'owner' ? ownerColorExpr(mode) : accessColorExpr()
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
      m.setFilter('selected', ['==', ['get', 'segment_id'], selected()?.segment_id ?? -1])
    })
  }

  onCleanup(() => map?.remove())

  return <div ref={(el) => (container = el)} class="map" />
}
