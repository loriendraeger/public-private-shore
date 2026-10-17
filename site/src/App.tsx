import type { JSX } from 'solid-js'

import Panel from './components/Panel'
import MapView from './map/MapView'

export default function App(): JSX.Element {
  return (
    <div class="app">
      <Panel />
      <MapView />
    </div>
  )
}
