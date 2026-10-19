import * as Plot from '@observablehq/plot'
import { createEffect, createSignal, type JSX, onCleanup, Show } from 'solid-js'

import { formatLong, formatPct, formatShort, toLong, toShort } from '../lib/units'
import { type Metric, metric, units } from '../state/store'
import HoverTip, { onScrollHide, rowAt, type TipAt } from './HoverTip'
import type { Score } from './measures'
import { TYPE_LABEL } from './ScoreTable'

interface Datum {
  name: string
  value: number
  label: string
  /** The full row, for the tooltip. */
  score: Score
}

function cssVar(name: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim()
}

function datum(s: Score, m: Metric): Datum | null {
  const u = units()
  const name = s.muni.name
  switch (m) {
    case 'pct':
      return s.pct === null ? null : { name, value: s.pct * 100, label: formatPct(s.pct), score: s }
    case 'distance':
      return {
        score: s,
        name,
        value: toLong(s.numeratorM, u),
        label: formatLong(s.numeratorM, u),
      }
    case 'perThousand':
      return {
        score: s,
        name,
        value: toShort(s.perThousandM, u),
        label: formatShort(s.perThousandM, u),
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
  const [hover, setHover] = createSignal<{ score: Score; at: TipAt } | null>(null)
  onScrollHide(() => setHover(null))
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
      // 22 px per row, plus 20 px top and 44 px bottom margins
      height: Math.max(120, data.length * 22 + 64),
      marginLeft: 200,
      marginRight: 64,
      marginBottom: 44,
      style: { background: 'transparent', color: ink, fontSize: '12px' },
      x: {
        label: axisLabel(m, u === 'metric'),
        labelAnchor: 'center',
        labelOffset: 36,
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
      ],
    })
    // Hovering anywhere on a row shows the municipality's whole table row.
    const names = data.map((d) => d.name)
    plot.addEventListener('pointermove', (e) => {
      const { offsetY, clientX, clientY } = e as PointerEvent
      const name = rowAt(plot, names, offsetY)
      const d = data.find((x) => x.name === name)
      setHover(d ? { score: d.score, at: { x: clientX, y: clientY } } : null)
    })
    plot.addEventListener('pointerleave', () => {
      setHover(null)
    })
    setHover(null)
    el.replaceChildren(plot)
  }

  createEffect(draw)

  return (
    <>
      <div
        class="chart"
        ref={(e) => {
          el = e
          ro.observe(e)
        }}
      />
      <Show when={hover()}>
        {(h) => (
          <HoverTip at={h().at}>
            <dl class="rows">
              <dt>Municipality</dt>
              <dd>{h().score.muni.name}</dd>
              <dt>Type</dt>
              <dd>{TYPE_LABEL[h().score.muni.muni_type]}</dd>
              <dt>Share</dt>
              <dd>{h().score.pct === null ? '—' : formatPct(h().score.pct ?? 0)}</dd>
              <dt>Counted</dt>
              <dd>{formatLong(h().score.numeratorM, units())}</dd>
              <dt>Out of</dt>
              <dd>{formatLong(h().score.denominatorM, units())}</dd>
              <dt>Per 1,000 residents</dt>
              <dd>{formatShort(h().score.perThousandM, units())}</dd>
              <dt>Population</dt>
              <dd>{h().score.muni.population.toLocaleString()}</dd>
            </dl>
          </HoverTip>
        )}
      </Show>
    </>
  )
}
