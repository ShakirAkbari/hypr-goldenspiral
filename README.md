# goldenspiral tiling layout

A custom [Hyprland](https://hypr.land) tiling layout, written in Lua, not a
compiled plugin. The window you're working in is a large **mainstage** on the
centre-right; every other window reflows into a **C** that hugs the mainstage's
left edge and its bottom edge, in roughly golden-ratio (φ ≈ 1.618) proportion.

Opening a window promotes it to the mainstage and pushes other apps one slot
down the C. This is the key departure from dwindle: a new window lands in the
**biggest** tile, not a fresh half-of-a-half. You always get full room to work
in whatever you just opened, and the windows you're not touching are the ones
that shrink. The whole layout recomputes on every add / remove / re-rank, so the
arrangement always reflects the current window order rather than wherever a
split-tree happened to branch.

It's a mix of two of Hyprland's stock layouts. From **master** (specifically
center-master) it takes the idea of one dominant tile that everything else
orbits. From **dwindle** it takes the tree-style recursive
subdivision of the leftover space: the C is the leftover area split down and
then across, the same "keep halving what's left" move dwindle makes, just driven
by an explicit recency order instead of a persistent split tree.

![goldenspiral with six windows](screenshots/goldenspiral.png)

```
+----------+---------------------------------+
|          |                                 |
| rank 2   |          mainstage (1)          |
|          |                                 |
+----------+---------------------------------+
|          |  4    |  5    |  6   | [app bar]|
| rank 3   |       |       | (over the bar,   |
|          |       |       |  stops above it) |
+----------+-------+-------+------------------+
  left column          bottom strip
```

- **Slot 1**: mainstage, right side. Full height (stopping above the app bar if
  present) until a strip forms, then it stops above the strip.
- **Slots 2 and 3**: the left column, always exactly these two boxes. Rank 2 is
  the upper one and is as tall as the mainstage; rank 3 fills the rest, lining
  up with the strip band. The bar and strip never touch the left column.
- **Slots 4, 5, ...**: the bottom strip under the mainstage. Tall tiles that
  fill left to right then wrap upward once a tile would fall below
  `min_tile_w`. The bottom row is split at the app bar's left edge: columns to
  its left run to the work-area floor, columns over the bar stop above it. The
  over-the-bar side gets the wider share of columns (two to the left's one at
  the defaults).

With 2-3 windows there's no strip: the mainstage takes the whole right side
(above the bar) and the left column holds one box (n=2) or both (n=3, split at
`left_split`).

It pairs well with a companion **app bar**,
[hypr-chronobar](https://github.com/ShakirAkbari/hypr-chronobar): a separate
project you install on its own. When it's running, goldenspiral automatically
keeps tiles out of its bottom-right corner. See [App bar](#app-bar) below.

See [`docs/DESIGN.md`](docs/DESIGN.md) for the reasoning behind every part of
this.

## Requirements

- Hyprland with the **Lua config system** (0.55+; developed on 0.56.2), which
  provides `hl.layout.register` and the `hl` / `o` config globals. This is what
  [Omarchy](https://omarchy.org) ships. A plain `hyprland.conf` setup would need
  the equivalent Lua entrypoint.
- The layout itself has no dependencies; it's one Lua file. The app bar is a
  separate install -- see [hypr-chronobar](https://github.com/ShakirAkbari/hypr-chronobar)
  for its own requirements.

## Install

```sh
git clone https://github.com/ShakirAkbari/hypr-goldenspiral
cd hypr-goldenspiral
./install.sh
```

`install.sh` symlinks `goldenspiral.lua` into `~/.config/hypr/hypr/`. A
`git pull` then updates it in place.

Then require it **after** whatever sets `general:layout`, so it wins:

```lua
-- ~/.config/hypr/hyprland.lua  (or wherever your requires live)
require("hypr.goldenspiral")
```

```sh
hyprctl reload
hyprctl configerrors   # expect no output
```

The layout registers itself, sets `general.layout = "lua:goldenspiral"`, and
binds the controls below. Want the app bar too? Install
[hypr-chronobar](https://github.com/ShakirAkbari/hypr-chronobar) separately
(it has its own installer and autostarts itself); goldenspiral needs no
configuration to cooperate with it, and works identically with it absent.

## Keybinds

| Key | Action |
| --- | --- |
| `SUPER + M` | promote the focused window to the mainstage |
| `SUPER + CTRL + DOWN` / `UP` | move the focused window down / up the C |
| `SUPER + =` / `-` | widen / narrow the mainstage |
| `SUPER + [` / `]` | grow / shrink the bottom strip |
| `SUPER + 0` | reset proportions |

Controls go through `hl.dsp.layout("<msg>")`. From a shell the equivalent is
`hyprctl dispatch 'hl.dsp.layout("promote")'`; the bare
`hyprctl dispatch layoutmsg promote` form does **not** work on the Lua config.

Available messages: `promote`, `swapnext`, `swapprev`, `grow`, `shrink`,
`taller`, `shorter`, `reset`, `leftfrac <0.2..0.5>`, `dragsnap`, `debug`.

## Drag and drop

Drag a tiled window with `SUPER + left-mouse` (Omarchy's default move bind) and
drop it into one of three zones. It goes to the **front** of that zone, no
finer aim than the zone itself:

| Drop zone | Where the window lands |
| --- | --- |
| **MAIN**: the mainstage (top-right) | the mainstage (rank 1) |
| **SIDE**: the whole left column | top of the left column (rank 2) |
| **BOTTOM**: the strip under the mainstage | the first strip slot |

Everything between the window's old and new rank shifts one step along the C.

Hyprland's Lua layout API exposes no drag or drop event. But a drag *pick-up*
floats the window, so on drop Hyprland hands it back to the layout as a brand
new tile, and any window id the layout has placed before is taken to be a
returning drop rather than a new window. Its drop point (window centre) picks
the zone. A genuinely new window still goes straight to the mainstage.

Turn the whole behaviour off with the `dragsnap` message (a dropped window
then just returns to the mainstage like any new one); `debug` toggles a
notification showing the rank each drop resolved to.

## App bar

[hypr-chronobar](https://github.com/ShakirAkbari/hypr-chronobar) is a
separate project: a time-ordered dock that runs as its own Quickshell
layer-shell panel in the bottom-right corner. Install it independently
(it has its own repo, README and installer); goldenspiral needs no
configuration to cooperate with it.

goldenspiral reads the rectangle chronobar publishes to
`~/.cache/hypr-chronobar/geometry.json` and carves it out of the work area:
the mainstage stops above it, or above the strip once one forms, and the
strip's bottom row is split at its left edge so no tile overlaps it. The left
column is never touched by the bar. There's no window to recognise or pin --
chronobar is a layer-shell surface, positions itself, and is never a tiled
target -- so nothing here breaks if you don't install it, and nothing over
there depends on goldenspiral either. See hypr-chronobar's own README for its
zones, config and keybinds.

## Tuning

Edit the `state` table at the top of `goldenspiral.lua`:

| field | default | meaning |
| --- | --- | --- |
| `left_frac` | `0.382` | left-column width as a fraction of the work area |
| `bottom_frac` | `0.34` | bottom-strip band height as a fraction of the work area (`taller` / `shorter` adjust it) |
| `left_split` | `0.66` | top-left box's share of the left column when there is no strip (with a strip the split follows the mainstage bottom) |
| `min_tile_w` | `0.18` | bottom-strip tiles never get narrower than this; extra windows wrap to new rows |
| `drag_snap` | `true` | send a dragged-and-dropped window to the front of its drop zone |

## How it works

`state.order` is an explicit list of window `stable_id`s, `order[1]` being the
mainstage. Each `recalculate`:

1. `ranked(ctx)` reconciles that list with the live targets: prunes closed
   windows, front-inserts genuinely new ones (newest first), and parks any
   *returning* window (a known id handed back as fresh, i.e. a drop) at the
   end for step 3.
2. `read_bar_geometry()` reads chronobar's published rectangle, if it's
   running, giving the carve for step 3.
3. `slots(area, n, carve)`, a pure function, returns `n` slot rectangles in
   rank order for the work area, window count, and the bar carve.
4. `place_returning` moves each dropped window to the front of its drop zone
   (`zone_rank` reads the zone from the slot boxes; see
   [Drag and drop](#drag-and-drop)), then `state.order` is re-materialised.
5. each window is placed with `target:place(box)`, which applies gaps, reserved
   area and pseudotiling; every placed id is recorded in `state.seen`.

`layout_msg` mutates `state.order` (`promote` / `swapnext` / `swapprev`) or the
`state` flags and proportions, and returns `true` to trigger a re-layout.

## Tests

`tests/geometry_spec.lua` mocks the config API, loads the layout, and asserts on
the placement logic (ranking, promote, swap, new-window-takes-mainstage,
row-wrap, small-N, and the app-bar carve). Runs under any Lua 5.x:

```sh
lua tests/geometry_spec.lua
```

## Credits

Concept, layout geometry, slot model, recency ranking, the minimum-size /
row-wrap rule and the promote / shuffle interactions are **all designed by
[Shakir Akbari](https://github.com/ShakirAkbari)**. The Lua implementation was written
with Claude Code to Shakir's design.

## License

[MIT](LICENSE) © 2026 Shakir Akbari
