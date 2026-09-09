# Design notes

The whole concept — the mainstage, the C-wrap, the recency ranking, the
minimum-size / row-wrap rule, the promote/shuffle interactions — was designed by
**Shakir Akbari**. This document records the reasoning so the layout can be
extended without losing the intent.

## Goal

A stacking-WM feel inside a tiler: one window you are working in should be big
and in a consistent place, and everything else should arrange itself around it
in a predictable, glanceable shape — without manual splitting.

## Why not a built-in layout

| Layout | Why it falls short of the goal |
| --- | --- |
| `dwindle` | A new window splits **the focused tile**, so the rest of the screen does not move. There is no notion of "the window I'm in is the big one". |
| `dwindle` w/ tuned `default_split_ratio` | Gets the newest window big, but still only re-tiles one branch; older windows never reflow as a group. |
| `master` (centre) | New window can take the master slot, but the stack is a plain column — it cannot wrap the master on two sides, and it cannot hold the specific 2a/2b/2c + bottom-strip shape. |

The requirement that **all** windows reflow whenever the set changes is the line
none of the built-ins cross. That needs a layout that recomputes every box from
a single ordered list on each `recalculate` — i.e. a custom layout.

## The C-wrap

```
+----------+---------------------------+
|  2a      |                           |
+----------+        mainstage (1)      |
|  2b      |                           |
+----------+                           |
|  2c      +---------------------------+
+----------+  3a   |  3b   |  3c  ...  |
+----------+-------+-------+-----------+
```

- **Mainstage** anchored centre-right so the eye has a fixed home.
- **Left column** (`2a` → `2c`, top to bottom) is the C's left stroke. `2c` is
  deliberately short — it is the "just keep an eye on it" slot.
- **Bottom strip** (`3a`, `3b`, …) is the C's bottom stroke, tucked under the
  mainstage. Equal columns.
- Proportions start near the golden ratio (`left_frac = 0.382`) but are not
  dogmatic about it — legibility of the mainstage wins.

Rank order fills the slots `1 → 2a → 2b → 2c → 3a → 3b → …`, so the further a
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
- **Closed window** → pruned from `order`; everything below it shifts up.

Ranking is kept as an explicit list rather than derived purely from window age
so that `promote` and the shuffles are possible at all.

## Minimum size instead of infinite shrink

Past a certain count, splitting the bottom strip into ever-thinner columns is
useless. `min_tile_w` sets a floor: when another column would breach it, the
strip **wraps to a new row** and grows upward, compressing the mainstage (down
to a hard floor of 30 % height). Tiles stay a usable size; the mainstage pays
for the crowd.

## Small-N behaviour

With 2–4 windows there is no bottom strip: the mainstage is full height and the
left column stretches (one half-height tile at 3 windows, the 2a/2b/2c split at
4). The C only forms once there is enough to wrap with.

## Implementation shape

- `ranked(ctx)` — reconcile `state.order` with live targets, return them ordered.
- `slots(area, n)` — pure function: given the work area and a count, return `n`
  slot rectangles in rank order.
- `recalculate(ctx)` — `ranked` → `slots` → `target:place(box)` per window.
- `layout_msg(ctx, msg)` — mutate `state` (order or proportions), return `true`
  to trigger a re-layout.

Keeping `slots()` pure makes the geometry easy to unit-test in plain Lua with a
mock `ctx` (see `tests/`).

## Possible extensions

- Configurable mainstage anchor (centre-left / top variants of the C).
- Per-window "pin to slot" so a chat window always stays in `2c`.
- A `focus-follows-rank` mode where cycling focus walks the C in order.
