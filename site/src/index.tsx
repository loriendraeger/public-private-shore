import './styles.css'

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
render(() => <App />, root)
