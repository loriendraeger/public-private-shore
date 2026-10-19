import { defineConfig } from 'vite'
import solid from 'vite-plugin-solid'

export default defineConfig({
  plugins: [solid()],
  // Served from https://<user>.github.io/public-private-shore/ (GitHub Pages project site).
  base: '/public-private-shore/',
  // MapLibre's worker is an ES module (it imports a shared chunk).
  worker: { format: 'es' },
})
