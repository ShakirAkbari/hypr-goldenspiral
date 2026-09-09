# goldenspiral

A custom [Hyprland](https://hypr.land) tiling layout, written in Lua — no
compiled plugin. The window you're working in is a large **mainstage** on the
centre-right; every other window reflows into a **C** that hugs the mainstage's
left edge and its bottom edge, in roughly golden-ratio (φ ≈ 1.618) proportion.

Opening a window promotes it to the mainstage and pushes everyone else one slot
down the C. This is the key departure from dwindle: a new window lands in the
**biggest** tile, not a fresh half-of-a-half. You always get full room to work
in whatever you just opened, and the windows you're not touching are the ones
that shrink. The whole layout recomputes on every add / remove / re-rank, so the
arrangement always reflects the current window order rather than wherever a
split-tree happened to branch.

It's a mix of two of Hyprland's stock layouts. From **master** (specifically
center-master) it takes the idea of one dominant tile that everything else
orbits — here the mainstage. From **dwindle** it takes the tree-style recursive
subdivision of the leftover space: the C is the leftover area split down and
then across, the same "keep halving what's left" move dwindle makes, just driven
by an explicit recency order instead of a persistent split tree.

![goldenspiral with six windows](screenshots/goldenspiral.png)

*Six windows: OBS on the mainstage, a left column of three (`2a`/`2b`/`2c`) and a
two-tile bottom strip wrapping it into a C.*

```
+----------+---------------------------+
|  2a      |                           |
+----------+        mainstage (1)      |
|  2b      |                           |
+----------+                           |
|  2c      +---------------------------+
+----------+  3a   |  3b   |  3c  ...  |
+----------+-------+-------+-----------+
     left column          bottom strip
   (C's left stroke)    (C's bottom stroke)
```

- **Slot 1** — mainstage, right ~62 % wide, ~82 % tall.
- **Slots 2a / 2b / 2c** — left column, top to bottom (`2c` is the minimum size).
- **Slots 3a, 3b, …** — bottom strip under the mainstage, equal columns.
  Once a tile would fall below `min_tile_w` the strip wraps into more rows
  (growing upward, shrinking the mainstage) instead of shrinking tiles further.

With 2–4 windows there's no bottom strip: the mainstage runs full height and the
left column stretches to fill.

See [`docs/DESIGN.md`](docs/DESIGN.md) for the reasoning behind every part of
this.

## Requirements

- Hyprland with the **Lua config system** (0.55+; developed on 0.56.2), which
  provides `hl.layout.register` and the `hl` / `o` config globals. This is what
  [Omarchy](https://omarchy.org) ships. A plain `hyprland.conf` setup would need
  the equivalent Lua entrypoint.

## Install

It's one file. Put it next to your other Hyprland Lua files and require it
**after** whatever sets `general:layout`, so it wins:

```sh
cp goldenspiral.lua ~/.config/hypr/hypr/goldenspiral.lua
```

```lua
-- ~/.config/hypr/hyprland.lua  (or wherever your requires live)
require("hypr.goldenspiral")
```

```sh
hyprctl reload
hyprctl configerrors   # expect no output
```

The file registers the layout, sets `general.layout = "lua:goldenspiral"`, and
binds the controls below.

## Keybinds

| Key | Action |
| --- | --- |
| `SUPER + M` | promote the focused window to the mainstage |
| `SUPER + CTRL + DOWN` / `UP` | move the focused window down / up the C |
| `SUPER + =` / `-` | widen / narrow the mainstage |
| `SUPER + [` / `]` | grow / shrink the bottom strip |
| `SUPER + 0` | reset proportions |

Controls go through `hl.dsp.layout("<msg>")`. From a shell the equivalent is
`hyprctl dispatch 'hl.dsp.layout("promote")'` — the bare
`hyprctl dispatch layoutmsg promote` form does **not** work on the Lua config.

Available messages: `promote`, `swapnext`, `swapprev`, `grow`, `shrink`,
`taller`, `shorter`, `reset`, `leftfrac <0.2..0.5>`.

## Tuning

Edit the `state` table at the top of `goldenspiral.lua`:

| field | default | meaning |
| --- | --- | --- |
| `left_frac` | `0.382` | left-column width as a fraction of the work area |
| `bottom_frac` | `0.18` | bottom-strip row height as a fraction of the work area |
| `top_split` | `0.41` | height of `2a` and of `2b` (`2c` gets the remainder) |
| `min_tile_w` | `0.16` | bottom-strip tiles never get narrower than this; extra windows wrap to new rows |

## How it works

`state.order` is an explicit list of window `stable_id`s, `order[1]` being the
mainstage. Each `recalculate`:

1. `ranked(ctx)` reconciles that list with the live targets — prunes closed
   windows, front-inserts new ones (newest first).
2. `slots(area, n)` — a pure function — returns `n` slot rectangles in rank
   order for the current work area and window count.
3. each window is placed with `target:place(box)`, which applies gaps, reserved
   area and pseudotiling.

`layout_msg` mutates `state.order` (`promote` / `swapnext` / `swapprev`) or the
`state` proportions, and returns `true` to trigger a re-layout.

## Tests

`tests/geometry_spec.lua` mocks the config API, loads the layout, and asserts on
the placement logic (ranking, promote, swap, new-window-takes-mainstage,
row-wrap, small-N). Runs under any Lua 5.x:

```sh
lua tests/geometry_spec.lua
```

## Credits

Concept, layout geometry, slot model, recency ranking, the minimum-size /
row-wrap rule and the promote / shuffle interactions — **all designed by
[Shakir Akbari](https://github.com/ShakirAkbari)**. The Lua implementation was written
with Claude Code to Shakir's design.

## License

[MIT](LICENSE) © 2026 Shakir Akbari
