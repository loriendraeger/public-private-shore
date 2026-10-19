import * as Plot from '@observablehq/plot'
import { createEffect, createMemo, For, type JSX, onCleanup, Show } from 'solid-js'

import { ALL_CATEGORIES, CATEGORIES } from '../lib/categories'
import type { Category } from '../lib/contract'
import { formatLong, formatPct } from '../lib/units'
import { CATEGORY_GROUP, CATEGORY_GROUPS, entries, type Mode } from '../map/colors'
import { measure, stats, units } from '../state/store'
import HoverTip, { createChartTip, rowAt } from './HoverTip'
import type { Score } from './measures'
import { rowLayout } from './rows'

// What each municipality's shore is made of: one 100% stacked bar per municipality,
// a segment per category the current report measures against. Counted categories come
// first, so the left part of each bar is the municipality's share (a tick marks where
// it ends). Nine categories are too many hues to tell apart, so segments take the map's
// three group colors (validated for color-blind readers); the tooltip names each one.

const mode: Mode = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'

interface Segment {
  name: string
  category: Category
  m: number
  /** Percent of the municipality's measured shore. */
  x1: number
  x2: number
  color: string
  counts: boolean
}

function cssVar(name: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim()
}

export default function Composition(props: { scores: Score[] }): JSX.Element {
  const segments = createMemo((): Segment[] => {
    const s = stats()
    const m = measure()
    if (!s) {
      return []
    }
    const ids = new Set(props.scores.map((x) => x.muni.muni_id))
    const byMuni = new Map<number, Map<Category, number>>()
    for (const row of s.shore) {
      if (ids.has(row.muni_id) && m.water.includes(row.water_kind)) {
        const cats = byMuni.get(row.muni_id) ?? new Map<Category, number>()
        cats.set(row.category, (cats.get(row.category) ?? 0) + row.length_m)
        byMuni.set(row.muni_id, cats)
      }
    }
    // Counted categories first, then the rest of the denominator, each in display order.
    const order = [
      ...ALL_CATEGORIES.filter((c) => m.numerator.includes(c)),
      ...ALL_CATEGORIES.filter((c) => m.denominator.includes(c) && !m.numerator.includes(c)),
    ]
    const ranked = [...props.scores]
      .filter((x) => x.denominatorM > 0)
      .sort((a, b) => (b.pct ?? 0) - (a.pct ?? 0))
    return ranked.flatMap((score) => {
      const cats = byMuni.get(score.muni.muni_id)
      let x = 0
      return order.flatMap((c) => {
        const len = cats?.get(c) ?? 0
        if (len <= 0) {
          return []
        }
        const w = (len / score.denominatorM) * 100
        const seg: Segment = {
          name: score.muni.name,
          category: c,
          m: len,
          x1: x,
          x2: x + w,
          color: CATEGORY_GROUPS[CATEGORY_GROUP[c]].color[mode],
          counts: m.numerator.includes(c),
        }
        x += w
        return [seg]
      })
    })
  })

  const { tip, attach } = createChartTip<Segment>()

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
    const data = segments()
    if (!el) {
      return
    }
    const names = [...new Set(data.map((d) => d.name))]
    // Where the counted part of each bar ends.
    const ends = names.map((name) => ({
      name,
      x: Math.max(0, ...data.filter((d) => d.name === name && d.counts).map((d) => d.x2)),
    }))
    const ink = cssVar('--ink-2')
    const surface = cssVar('--surface')
    const rows = rowLayout(width, names, ink)
    const plot = Plot.plot({
      width,
      height: rows.height,
      marginLeft: rows.marginLeft,
      marginRight: 16,
      marginBottom: 44,
      style: { background: 'transparent', color: ink, fontSize: '12px' },
      x: {
        label: 'Share of measured shore (%)',
        labelAnchor: 'center',
        labelOffset: 36,
        domain: [0, 100],
      },
      y: rows.y,
      marks: [
        Plot.barX(data, {
          x1: 'x1',
          x2: 'x2',
          y: 'name',
          fill: 'color',
          // 2px surface gap between segments
          stroke: surface,
          strokeWidth: 2,
          insetTop: rows.insetTop,
          insetBottom: rows.insetBottom,
        }),
        Plot.tickX(ends, {
          x: 'x',
          y: 'name',
          stroke: cssVar('--ink'),
          strokeWidth: 2,
          insetTop: rows.insetTop,
          insetBottom: rows.insetBottom,
        }),
        ...rows.nameMarks,
      ],
    })

    // Plot's pointer picks the nearest segment midpoint, which can be the wrong one
    // beside a wide segment; find the segment under the pointer from the scales instead.
    const x = plot.scale('x')
    attach(plot, (e) => {
      const v = x?.invert?.(e.offsetX) as number | undefined
      const name = rowAt(plot, names, e.offsetY)
      return v === undefined || name === undefined
        ? undefined
        : data.find((d) => d.name === name && v >= d.x1 && v <= d.x2)
    })
    el.replaceChildren(plot)
  }

  createEffect(draw)

  return (
    <section class="composition">
      <ul class="legend inline">
        <For each={entries(CATEGORY_GROUPS)}>
          {([, g]) => (
            <li>
              <span class="swatch" style={{ background: g.color[mode] }} />
              {g.label}
            </li>
          )}
        </For>
        <li>
          <span class="tick-swatch" /> End of the counted shore
        </li>
      </ul>
      <p class="muted">
        Each segment is one category; hover or tap for details. Bars cover the shore the report
        measures against, counted categories first.
      </p>
      <div
        class="chart"
        ref={(e) => {
          el = e
          ro.observe(e)
        }}
      />
      <Show when={tip()}>
        {(h) => (
          <HoverTip at={h().at}>
            <dl>
              <dt>{h().value.name}</dt>
              <dd>{CATEGORIES[h().value.category].label}</dd>
              <dd>
                {formatLong(h().value.m, units())} ·{' '}
                {formatPct((h().value.x2 - h().value.x1) / 100)}
              </dd>
              <dd class="muted">In this report: {h().value.counts ? 'Counts' : 'Out of'}</dd>
            </dl>
          </HoverTip>
        )}
      </Show>
    </section>
  )
}
