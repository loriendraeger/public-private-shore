import './styles.css'

import { HashRouter, Navigate, Route } from '@solidjs/router'
import { render } from 'solid-js/web'

import App from './App'
import { loadStats } from './state/store'

const root = document.getElementById('root')
if (!root) {
  throw new Error('index.html is missing #root')
}
loadStats(`${import.meta.env.BASE_URL}data/stats.json`).catch((e: unknown) => {
  console.error('Failed to load stats.json', e)
})
// Hash URLs (#/map, #/scorecard, #/about): GitHub Pages can't serve index.html for other paths.
// App is the shell for every route; the routes themselves render nothing.
render(
  () => (
    <HashRouter root={App}>
      <Route path="/map" />
      <Route path="/scorecard" />
      <Route path="/about" />
      <Route path="/" component={() => <Navigate href="/map" />} />
      <Route path="*" component={() => <Navigate href="/map" />} />
    </HashRouter>
  ),
  root,
)
