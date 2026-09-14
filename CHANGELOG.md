# Changelog

All notable changes to this project are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- `install.sh` now installs [hypr-chronobar](https://github.com/ShakirAkbari/hypr-chronobar)
  as a dependency instead of just pointing at it: clones it into
  `~/Projects/hypr-chronobar` if missing, updates it if the checked out
  commit predates `8b8b6e6` (the commit that started publishing
  `geometry.json`, the only thing this layout reads from it), runs its own
  `install.sh`, and adds the `qs -c chronobar` autostart line to
  `~/.config/hypr/autostart.lua` if it's not already there. Idempotent;
  skipped with a warning if `git` is unavailable or something other than a
  git checkout already occupies that directory.
- **App bar cooperation**: the layout carves its bottom-right corner out of
  the work area for [hypr-chronobar](https://github.com/ShakirAkbari/hypr-chronobar),
  a separate, standalone project you install independently. `recalculate`
  reads the rectangle chronobar publishes to
  `~/.cache/hypr-chronobar/geometry.json` (`read_bar_geometry`); the
  bottom-row strip columns over its x-range stop above it, and everything
  else ignores it. No configuration needed on this side; the layout works
  identically with the bar absent.
- `workspace` config key: scopes golden-spiral to a single workspace via
  `hl.workspace_rule`, instead of making it the global layout. Every other
  workspace keeps Hyprland's normal default layout. Empty by default (global,
  unchanged behavior for existing users).
- CI (`.github/workflows/ci.yml`): runs the Lua geometry tests and
  `tests/no-fancy-dashes.sh`, which fails on any em or en dash in a tracked
  file.

### Removed
- The vendored `bar/chronobar.py` (a GTK4 reimplementation of the app bar,
  recognised by window class and pinned into the layout as a tiled target)
  and its `homeMonitor` config key. It never shipped in a release: it
  duplicated [hypr-chronobar](https://github.com/ShakirAkbari/hypr-chronobar),
  drifted from that project's bug fixes almost immediately, and solved a
  non-problem (see `docs/DESIGN.md`, "The app bar"). `barWidthFraction` /
  `barHeight` in `~/.config/goldenspiral/bar.json` went with it; the carve
  size now comes straight from chronobar's own published geometry.

### Changed
- Docs and comments now use plain ASCII punctuation only (no em or en dashes).
- **Slot model reworked.** The left column is now always exactly two full-height
  boxes, rank 2 the upper one (was `2a`/`2b`/`2c`, where the second-biggest
  window drifted to the middle or bottom and `2c` was unusably small). The
  bottom strip is now tall tiles that run down to the work-area floor and fill
  the space beside the app bar; a strip column over the bar's x-range stops
  above the bar. The mainstage is full height until a strip forms (n >= 4),
  then stops above it. New `state.left_split`; `bottom_frac` default raised to
  `0.34`, `min_tile_w` to `0.18`; `top_split` removed.
- `slots` takes an optional third argument, the app bar footprint
  (`{bar_w, bar_h}`); called with two arguments it behaves exactly as before.
- "Reset proportions" moved from `SUPER + 0` to `SUPER + R`, freeing `SUPER + 0`
  (and its shift/alt variants) for Omarchy's default workspace-10 bindings,
  which it would otherwise silently shadow whenever `workspace` scopes the
  layout to that key's workspace.

## [0.2.0] - 2026-09-08

### Added
- Drag-and-drop re-ranking, three zones. Drag a tiled window and drop it in the
  MAIN zone (→ mainstage), the SIDE zone (→ top of the left column) or the
  BOTTOM zone (→ first strip slot); the windows in between shift one step along
  the C. The Lua layout API has no drag event, but a drag pick-up floats the
  window, so on drop it returns as a fresh tile, and any `stable_id` the layout
  has placed before is treated as a returning drop and placed by zone rather
  than sent to the mainstage. New `state.drag_snap` flag (default on) and
  `dragsnap` / `debug` `layout_msg` toggles.

### Changed
- Rebound the along-the-C shuffle from `SUPER+CTRL+L`/`H` to
  `SUPER+CTRL+DOWN`/`UP`, since `SUPER+CTRL+L` is Omarchy's lock-screen shortcut.

## [0.1.0] - 2026-09-08

First release.

### Added
- `lua:goldenspiral` custom layout registered through Hyprland's
  `hl.layout.register` API, no compiled plugin.
- **C-wrap slot model**: mainstage on the centre-right; older windows fill a
  left column (`2a` / `2b` / `2c`) and a bottom strip (`3a`, `3b`, …) that
  together wrap the mainstage in a C.
- Full-layout reflow on every window add / remove / re-rank (unlike a
  split-tree layout, which only re-tiles the focused branch).
- Explicit `state.order` window ranking:
  - a new window is inserted at rank 1 (takes the mainstage);
  - `promote` sends the focused window to the mainstage;
  - `swapnext` / `swapprev` shuffle the focused window along the C.
- Minimum tile size (`min_tile_w`): once bottom-strip tiles would get narrower
  than the floor, the strip wraps into extra rows (growing upward, shrinking
  the mainstage) instead of shrinking tiles further.
- Adaptive behaviour for 2-4 windows: the mainstage runs full height and the
  left column stretches to fill.
- Adjustable proportions via `layout_msg`: `grow` / `shrink` (mainstage width),
  `taller` / `shorter` (bottom-strip height), `reset`, `leftfrac <0.2..0.5>`.
- Default keybinds: `SUPER+M`, `SUPER+CTRL+L`/`H`, `SUPER+=`/`-`, `SUPER+[`/`]`,
  `SUPER+0`.
