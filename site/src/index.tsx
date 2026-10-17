import './styles.css'

import { render } from 'solid-js/web'

import App from './App'

const root = document.getElementById('root')
if (!root) {
  throw new Error('index.html is missing #root')
}
render(() => <App />, root)
