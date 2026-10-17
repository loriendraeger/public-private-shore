import { createSignal } from "solid-js";
import type { ShoreProps } from "../lib/contract";

// App state as Solid signals. The map subscribes to these and updates paint/visibility
// in place; it is never re-created on a state change.

export type ColorBy = "owner" | "access";

export const [colorBy, setColorBy] = createSignal<ColorBy>("owner");

/** Show the `shore_alt` layer (alternative pipeline settings) instead of `shore`. */
export const [showAlt, setShowAlt] = createSignal(false);
/** Whether shore.pmtiles contains a `shore_alt` layer at all. */
export const [hasAlt, setHasAlt] = createSignal(false);

export const [selected, setSelected] = createSignal<ShoreProps | null>(null);
