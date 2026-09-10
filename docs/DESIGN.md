# Design notes

The whole concept (the mainstage, the C-wrap, the recency ranking, the
minimum-size / row-wrap rule, the promote/shuffle interactions) was designed by
**Shakir Akbari**. This document records the reasoning so the layout can be
extended without losing the intent.

## Goal

A stacking-WM feel inside a tiler: one window you are working in should be big
and in a consistent place, and everything else should arrange itself around it
in a predictable, glanceable shape, without manual splitting.

## Why not a built-in layout

| Layout | Why it falls short of the goal |
| --- | --- |
| `dwindle` | A new window splits **the focused tile**, so the rest of the screen does not move. There is no notion of "the window I'm in is the big one". |
| `dwindle` w/ tuned `default_split_ratio` | Gets the newest window big, but still only re-tiles one branch; older windows never reflow as a group. |
| `master` (centre) | New window can take the master slot, but the stack is a plain column: it cannot wrap the master on two sides, and it cannot hold the two-box left column plus floor-height bottom strip shape. |

The requirement that **all** windows reflow whenever the set changes is the line
none of the built-ins cross. That needs a layout that recomputes every box from
a single ordered list on each `recalculate`, i.e. a custom layout.

## The C-wrap

```
+----------+---------------------------------+
|  rank 2  |          mainstage (1)          |
+----------+---------------------------------+
|  rank 3  |  4   |  5   |  6  | [app bar]   |
+----------+------+------+-----+-------------+
```

- **Mainstage** anchored centre-right so the eye has a fixed home. Full height
  until a strip forms, then it stops above the strip.
- **Left column** is exactly two boxes, rank 2 on top. Both keep full height:
  the C's left stroke is always two equal, legible windows, not a stack that
  degrades to a sliver. This is the change from the earlier `2a/2b/2c` model,
  where the "second biggest" window drifted to the middle or bottom of the
  column and `2c` was too small to use.
- **Bottom strip** (ranks 4, 5, ...) is the C's bottom stroke, tucked under the
  mainstage. Tall tiles that run to the work-area floor and fill left to right,
  wrapping upward only past `min_tile_w`. The strip and the app bar share the
  bottom edge: a strip column over the bar's x-range stops above the bar; the
  columns to its left run to the floor. The bar floats over any small sliver of
  overlap.
- Proportions start near the golden ratio (`left_frac = 0.382`) but are not
  dogmatic about it; legibility of the mainstage wins.

Rank order fills the slots `1 -> 2 -> 3 -> 4 -> 5 -> ...`, so the further a
window is from your current focus history, the smaller and more peripheral its
slot.

## Recency ranking and re-ranking

`state.order` is a list of window `stable_id`s, `order[1]` = mainstage.

- **New window** → inserted at rank 1. Opening something makes it the mainstage
  and everyone else shifts one slot down the C.
- **`promote`** → the focused window jumps to rank 1. This is the "bring that
  back to the front" gesture.
- **`swapnext` / `swapprev`** → swap the focused window with its neighbour in
  the order, to hand-tune which peripheral slot something sits in.
- **Drag and drop** → drop a window in a zone and it goes to the front of that
  zone, the windows in between shifting one step (see below).
- **Closed window** → pruned from `order`; everything below it shifts up.

Ranking is kept as an explicit list rather than derived purely from window age
so that `promote` and the shuffles are possible at all.

## Drag and drop

The Lua layout API (`recalculate` + `layout_msg`, Hyprland 0.56.x) has **no**
drag, drop, mouse, or window-event hook. A custom layout is told nothing about
a drag directly. But it doesn't need to be:

**A drag pick-up floats the window.** Hyprland's move-drag converts a tiled
window to floating for the duration of the drag, which *removes it from the
tiled target list*. On drop it's converted back and **re-added as a fresh
target at the end of the list**. So from the layout's side a drag looks like:
the window vanishes, then a "new" window with the same `stable_id` appears.

`stable_id`s are monotonic and never reused, so a "new" id the layout has
placed before (`state.seen`) can only be a window that left the tiled set and
came back: a drop (or a workspace bounce, or an un-fullscreen; all want the
same treatment). That window is **not** sent to the mainstage like a genuine
new window. Instead its centre (still the drop point at the moment
`recalculate` runs, before it's been placed) picks a **zone**:

| Zone | Test | Goes to |
| --- | --- | --- |
| SIDE | `x` left of the mainstage | rank 2, top of the left column |
| BOTTOM | `y` below the mainstage | first strip slot |
| MAIN | otherwise | rank 1, the mainstage |

`zone_rank` reads those bounds straight off the slot boxes, so it always
matches the real geometry. Front of the zone, nothing finer; past the big
slots the order of the small-window line isn't worth aiming at.

An earlier version tried to *infer* the drag in place (watch for one window's
centre jumping far from where it was last placed) and snap to the nearest slot
*centre*. Two problems, both fixed by the current approach: the drag actually
removes the window so the "same set, one moved" test never held; and the
mainstage rectangle is large and central enough that its centre is the nearest
one across most of the screen, so nearly every drop promoted to the mainstage.

`state.drag_snap` (default `true`, toggled by the `dragsnap` message) turns it
off, so a dropped window is then treated as new and returns to the mainstage.
`debug` toggles a notification with the resolved rank.

### What is *not* possible

Drag-to-screen-edge gestures (e.g. fling a window at the top edge to
fullscreen it, drag it back down to re-tile) would need a drag/pointer hook
the layout API does not provide. The only route is an external process polling
`hyprctl cursorpos` with no real drag start/stop signal, which is not worth
building.

## Minimum size instead of infinite shrink

Past a certain count, splitting the bottom strip into ever-thinner columns is
useless. `min_tile_w` sets a floor: when another column would breach it, the
strip **wraps to a new row** and grows upward, compressing the mainstage (down
to a hard floor of 28 % height). Tiles stay a usable size; the mainstage pays
for the crowd.

## Small-N behaviour

With 2-3 windows there is no bottom strip: the mainstage is full height (the
app bar, if present, floats over its corner) and the left column holds one box
at n=2 or both at n=3. The strip, and the C, form at the 4th window.

## Implementation shape

- `ranked(ctx)`: reconcile `state.order` with live targets; return them
  ordered, plus the list of ids that came back from a drag.
- `slots(area, n, carve)`: pure function. given the work area, a count, and an
  optional `carve` (`{bar_w, bar_h}`, the app bar's footprint in the
  bottom-right corner), return `n` slot rectangles in rank order. `carve` only
  shortens the bottom-row strip columns that sit over the bar.
- `bar_geometry(area)`: pure function. the pinned bar's bottom-right box and its
  footprint.
- `zone_rank(area, boxes, n, x, y)`: which zone front a point maps to (1, 2,
  or the first strip slot).
- `place_returning(...)`: move each dropped window to its zone front; returns
  `true` if `state.order` changed.
- `recalculate(ctx)`: `ranked` → `slots` → `place_returning` → `target:place`
  per window, marking every placed id in `state.seen`.
- `layout_msg(ctx, msg)`: mutate `state` (order, flags or proportions), return
  `true` to trigger a re-layout.

Keeping `slots()` pure makes the geometry easy to unit-test in plain Lua with a
mock `ctx` (see `tests/`).

## The app bar

The bar is a normal window, not a layer-shell surface. That was a deliberate
choice: a wlr-layer-shell exclusive zone can only reserve a whole screen edge,
never a corner rectangle, so a layer-shell bar in the bottom-right corner would
either reserve the entire bottom strip (wasting the two thirds it does not use)
or reserve nothing and let windows tile under it. Making the bar an ordinary
tiled window hands the whole problem to the layout, which already places
rectangles for a living: `recalculate` gives the bar its own fixed box and
carves that box out of what everyone else gets. No geometry file, no
coordinate matching, one source of truth.

The bar is recognised by window class (`state.bar.class`). `ranked` pulls that
target out before building `state.order`, so the bar is never in the C and
never counts toward `n`. `recalculate` then:

1. `bar_geometry(area)` returns the bar box (bottom-right, `w_frac` wide,
   `h_px` tall) and its footprint `{bar_w, bar_h}`.
2. `bar_target:place(box)`.
3. `slots(area, n, footprint)` places the rest. The mainstage rises because the
   strip band below it is now tall, not because of the bar directly. The bar
   only matters to the bottom row of the strip: a column whose left edge is in
   the bar's x-range stops at the bar's top edge instead of the work-area
   floor. Columns to its left run to the floor even if they poke a little into
   the bar's x-range; the bar sits above them on the `top` layer.

The left column never sees the bar or the strip: it is always two full-height
boxes to the left of everything. That is the point of capping it at two, so the
"second biggest window" has one fixed home (rank 2, top-left) instead of
drifting down a three-tile stack.

`state.bar.w_frac` and `h_px` default in the Lua but are overridden by
`barWidthFraction` / `barHeight` in `~/.config/goldenspiral/bar.json`, which the
bar also reads, so the tile the layout draws and the window the bar paints stay
the same size. `read_bar_cfg` is the only impure part of the layout and is a
no-op under `_G.GOLDENSPIRAL_TEST`.

A `no_focus` window rule keeps the bar out of the focus cycle; it still arrives
as a layout target. `border_size = 0` and `rounding = 0` drop the chrome the
layout config would otherwise draw around it.

## Possible extensions

- Configurable mainstage anchor (centre-left / top variants of the C).
- Per-window "pin to slot" so a chat window always stays in the bottom-left box.
- A `focus-follows-rank` mode where cycling focus walks the C in order.
