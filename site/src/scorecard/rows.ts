import * as Plot from '@observablehq/plot'

/** Below this chart width, names go above the bars instead of beside them. */
const NARROW_PX = 560

/** Row layout for the scorecard's horizontal bar charts (one row per municipality).
 * Wide: a 200 px name column on the left. Narrow (phones): each name sits above its
 * bar, so the bars get the full width and names stay whole (several towns share a name
 * with a city or village, so abbreviating them gets confusing). */
export interface RowLayout {
  height: number
  marginLeft: number
  y: Plot.ScaleOptions
  /** Bar insets within a row. */
  insetTop: number
  insetBottom: number
  /** Offset from the row's center to the bar's center, for marks drawn on the bar. */
  barDy: number
  /** The name labels, when they aren't the y axis. */
  nameMarks: Plot.Markish[]
}

const TOP = 20
const BOTTOM = 44 // room for the tick labels and the axis label under them

export function rowLayout(width: number, names: string[], ink: string): RowLayout {
  if (width >= NARROW_PX) {
    return {
      height: Math.max(120, names.length * 22 + TOP + BOTTOM),
      marginLeft: 200,
      y: { label: null, domain: names },
      insetTop: 2,
      insetBottom: 2,
      barDy: 0,
      nameMarks: [],
    }
  }
  // 36 px rows: the name in the top half, a 14 px bar below it.
  const row = 36
  const insetTop = 18
  const insetBottom = 4
  return {
    height: names.length * row + TOP + BOTTOM,
    marginLeft: 4,
    y: { axis: null, domain: names, padding: 0 },
    insetTop,
    insetBottom,
    barDy: (insetTop + row - insetBottom) / 2 - row / 2,
    nameMarks: [
      Plot.text(names, {
        y: (d: string) => d,
        text: (d: string) => d,
        frameAnchor: 'left',
        textAnchor: 'start',
        dx: 4, // clear of the zero rule
        dy: insetTop / 2 - row / 2,
        fill: ink,
      }),
    ],
  }
}
