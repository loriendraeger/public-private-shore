import { type JSX, Show } from 'solid-js'

import Panel from './components/Panel'
import MapView from './map/MapView'
import Scorecard from './scorecard/Scorecard'
import { setUnits, setView, units, view } from './state/store'

export default function App(): JSX.Element {
  return (
    <div class="app">
      <header class="topbar">
        <nav class="tabs" role="tablist" aria-label="View">
          <button role="tab" aria-selected={view() === 'map'} onClick={() => setView('map')}>
            Map
          </button>
          <button
            role="tab"
            aria-selected={view() === 'scorecard'}
            onClick={() => setView('scorecard')}
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
