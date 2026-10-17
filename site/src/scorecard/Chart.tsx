import * as Plot from '@observablehq/plot'
import { createEffect, type JSX, onCleanup } from 'solid-js'

import { formatLong, formatPct, formatShort, toLong, toShort } from '../lib/units'
import { type Metric, metric, units } from '../state/store'
import type { Score } from './measures'

interface Datum {
  name: string
  value: number
  label: string
  littleShore: boolean
}

function cssVar(name: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim()
}

function datum(s: Score, m: Metric): Datum | null {
  const u = units()
  const name = s.muni.name + (s.littleShore ? ' *' : '')
  switch (m) {
    case 'pct':
      return s.pct === null
        ? null
        : { name, value: s.pct * 100, label: formatPct(s.pct), littleShore: s.littleShore }
    case 'distance':
      return {
        name,
        value: toLong(s.numeratorM, u),
        label: formatLong(s.numeratorM, u),
        littleShore: s.littleShore,
      }
    case 'perThousand':
      return {
        name,
        value: toShort(s.perThousandM, u),
        label: formatShort(s.perThousandM, u),
        littleShore: s.littleShore,
      }
  }
}

function axisLabel(m: Metric, isMetric: boolean): string {
  switch (m) {
    case 'pct':
      return 'Share of shore (%)'
    case 'distance':
      return `Shore (${isMetric ? 'km' : 'mi'})`
    case 'perThousand':
      return `Shore per 1,000 residents (${isMetric ? 'm' : 'ft'})`
  }
}

/** Ranked horizontal bars, one per municipality, for the current metric. */
export default function Chart(props: { scores: Score[] }): JSX.Element {
  let el: HTMLDivElement | undefined
  let width = 640
  const ro = new ResizeObserver(([entry]) => {
    if (Math.abs(entry.contentRect.width - width) > 4) {
      width = entry.contentRect.width
      draw()
    }
  })
  onCleanup(() => {
    ro.disconnect()
  })

  function draw(): void {
    if (!el) {
      return
    }
    const m = metric()
    const u = units()
    const data = props.scores
      .map((s) => datum(s, m))
      .filter((d): d is Datum => d !== null)
      .sort((a, b) => b.value - a.value)
    const ink = cssVar('--ink-2')
    const accent = cssVar('--accent')
    const plot = Plot.plot({
      width,
      height: Math.max(120, data.length * 22 + 40),
      marginLeft: 200,
      marginRight: 64,
      style: { background: 'transparent', color: ink, fontSize: '12px' },
      x: {
        label: axisLabel(m, u === 'metric'),
        grid: true,
        domain: m === 'pct' ? [0, 100] : undefined,
        nice: true,
      },
      y: { label: null, domain: data.map((d) => d.name) },
      marks: [
        Plot.barX(data, {
          x: 'value',
          y: 'name',
          fill: accent,
          // Fragile scores (little shore) are faded, and starred in the label.
          fillOpacity: (d: Datum) => (d.littleShore ? 0.4 : 1),
          rx: 3,
          insetTop: 2,
          insetBottom: 2,
        }),
        Plot.text(data, {
          x: 'value',
          y: 'name',
          text: 'label',
          textAnchor: 'start',
          dx: 4,
          fill: ink,
        }),
        Plot.ruleX([0], { stroke: ink }),
        Plot.tip(
          data,
          Plot.pointerY({
            x: 'value',
            y: 'name',
            title: (d: Datum) =>
              `${d.name.replace(/ \*$/, '')}\n${d.label}${d.littleShore ? '\nLittle shore: fragile score' : ''}`,
          }),
        ),
      ],
    })
    el.replaceChildren(plot)
  }

  createEffect(draw)

  return (
    <div
      class="chart"
      ref={(e) => {
        el = e
        ro.observe(e)
      }}
    />
  )
}
