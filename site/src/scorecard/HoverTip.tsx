import type * as Plot from '@observablehq/plot'
import { type Accessor, createSignal, type JSX, onCleanup } from 'solid-js'

/** Pointer position in viewport coordinates (MouseEvent clientX/clientY). */
export interface TipAt {
  x: number
  y: number
}

const GAP = 14
const EDGE = 8

/** A chart tooltip that floats over the page (position: fixed), so it is never clipped
 * by the chart's SVG and never makes the page longer (which flashed a scrollbar). It
 * stays inside the window, flipping above the pointer when there's no room below. */
export default function HoverTip(props: { at: TipAt; children: JSX.Element }): JSX.Element {
  let el: HTMLDivElement | undefined
  const [size, setSize] = createSignal({ w: 0, h: 0 })
  const ro = new ResizeObserver(() => {
    if (el) {
      setSize({ w: el.offsetWidth, h: el.offsetHeight })
    }
  })
  onCleanup(() => {
    ro.disconnect()
  })

  function left(): number {
    const { w } = size()
    return Math.min(Math.max(props.at.x - w / 2, EDGE), window.innerWidth - w - EDGE)
  }
  function top(): number {
    const { h } = size()
    const below = props.at.y + GAP
    return below + h > window.innerHeight - EDGE ? props.at.y - GAP - h : below
  }

  return (
    <div
      class="hover-tip"
      ref={(e) => {
        el = e
        ro.observe(e)
      }}
      style={{
        left: `${String(left())}px`,
        top: `${String(top())}px`,
        // Hidden until measured, so it doesn't flash at the wrong spot.
        visibility: size().w > 0 ? 'visible' : 'hidden',
      }}
    >
      {props.children}
    </div>
  )
}

/** Hide a tooltip when the page scrolls under it (no pointer event fires then). */
export function onScrollHide(hide: () => void): void {
  window.addEventListener('scroll', hide, { capture: true, passive: true })
  onCleanup(() => {
    window.removeEventListener('scroll', hide, { capture: true })
  })
}

/** The y-band row (a domain value) under a pointer's offsetY on a Plot chart, if any. */
export function rowAt(plot: Plot.Plot, rows: string[], offsetY: number): string | undefined {
  const y = plot.scale('y')
  const band = y?.bandwidth ?? 0
  // Count the padding between bands as part of the row, so there are no dead strips.
  const step = y?.step ?? band
  return rows.find((r) => {
    const top = y?.apply(r) as number | undefined
    return (
      top !== undefined &&
      offsetY >= top - (step - band) / 2 &&
      offsetY < top + band + (step - band) / 2
    )
  })
}

export interface ChartTip<T> {
  /** What to show and where, or null. */
  tip: Accessor<{ value: T; at: TipAt } | null>
  /** Wire a freshly drawn chart; `pick` finds the datum under the pointer, if any. */
  attach: (target: Element, pick: (e: MouseEvent) => T | undefined) => void
}

/** Tooltip state for one chart. A mouse shows it on hover. A click or tap shows it and
 * pins it (touch screens have no hover); tapping elsewhere on the chart moves it, and a
 * click outside the chart or a scroll closes it. */
export function createChartTip<T>(): ChartTip<T> {
  const [tip, setTip] = createSignal<{ value: T; at: TipAt } | null>(null)
  let pinned = false
  let chart: Element | null = null

  function close(): void {
    pinned = false
    setTip(null)
  }
  function show(e: MouseEvent, pick: (e: MouseEvent) => T | undefined): boolean {
    const value = pick(e)
    setTip(value === undefined ? null : { value, at: { x: e.clientX, y: e.clientY } })
    return value !== undefined
  }

  onScrollHide(close)
  function outside(e: PointerEvent): void {
    if (chart && !chart.contains(e.target as Node)) {
      close()
    }
  }
  window.addEventListener('pointerdown', outside, { capture: true })
  onCleanup(() => {
    window.removeEventListener('pointerdown', outside, { capture: true })
  })

  function attach(target: Element, pick: (e: MouseEvent) => T | undefined): void {
    chart = target
    close() // a redraw invalidates what the tooltip points at
    target.addEventListener('pointermove', (e) => {
      if ((e as PointerEvent).pointerType === 'mouse' && !pinned) {
        show(e as PointerEvent, pick)
      }
    })
    target.addEventListener('pointerleave', (e) => {
      if ((e as PointerEvent).pointerType === 'mouse' && !pinned) {
        setTip(null)
      }
    })
    target.addEventListener('click', (e) => {
      pinned = show(e as MouseEvent, pick)
    })
  }

  return { tip, attach }
}
