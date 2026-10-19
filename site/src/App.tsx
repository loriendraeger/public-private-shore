import { type RouteSectionProps, useNavigate } from '@solidjs/router'
import { type JSX, Show } from 'solid-js'

import Panel from './components/Panel'
import MapView from './map/MapView'
import Scorecard from './scorecard/Scorecard'
import { scorecardPath, ScorecardUrlSync } from './state/scorecardUrl'
import { setUnits, units, view } from './state/store'
import { mapPath, UrlSync } from './state/url'

/** The router's root: every route renders this shell; the route picks the view. */
export default function App(props: RouteSectionProps): JSX.Element {
  const navigate = useNavigate()
  return (
    <div class="app">
      <UrlSync />
      <ScorecardUrlSync />
      {/* Routes render nothing, except the redirect to #/map. */}
      {props.children}
      <header class="topbar">
        <nav class="tabs" role="tablist" aria-label="View">
          <button
            role="tab"
            aria-selected={view() === 'map'}
            onClick={() => {
              navigate(mapPath())
            }}
          >
            Map
          </button>
          <button
            role="tab"
            aria-selected={view() === 'scorecard'}
            onClick={() => {
              navigate(scorecardPath())
            }}
          >
            Scorecard
          </button>
        </nav>
        <div class="segmented" role="radiogroup" aria-label="Units">
          <button
            role="radio"
            aria-checked={units() === 'metric'}
            onClick={() => setUnits('metric')}
          >
            km
          </button>
          <button
            role="radio"
            aria-checked={units() === 'imperial'}
            onClick={() => setUnits('imperial')}
          >
            mi
          </button>
        </div>
      </header>
      {/* The map stays mounted (and hidden) on the scorecard tab, so it isn't rebuilt. */}
      <div class="body" classList={{ hidden: view() !== 'map' }}>
        <Panel />
        <MapView />
      </div>
      <Show when={view() === 'scorecard'}>
        <main class="body scroll">
          <Scorecard />
        </main>
      </Show>
    </div>
  )
}
