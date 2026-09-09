# Changelog

All notable changes to this project are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Heuristic drag-and-drop re-ranking. Drag a tiled window and drop it over
  another slot to give it that rank; the windows in between shift one step
  along the C. The Lua layout API has no drag event, so a drop is inferred
  from a lone window moving more than `max(120px, 8% of the screen diagonal)`
  from where it was last placed. New `state.drag_snap` flag (default on) and
  `dragsnap` / `debug` `layout_msg` toggles.

### Changed
- Rebound the along-the-C shuffle from `SUPER+CTRL+L`/`H` to
  `SUPER+CTRL+DOWN`/`UP` — `SUPER+CTRL+L` is Omarchy's lock-screen shortcut.

## [0.1.0] - 2026-09-08

First release.

### Added
- `lua:goldenspiral` custom layout registered through Hyprland's
  `hl.layout.register` API — no compiled plugin.
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
- Adaptive behaviour for 2–4 windows: the mainstage runs full height and the
  left column stretches to fill.
- Adjustable proportions via `layout_msg`: `grow` / `shrink` (mainstage width),
  `taller` / `shorter` (bottom-strip height), `reset`, `leftfrac <0.2..0.5>`.
- Default keybinds: `SUPER+M`, `SUPER+CTRL+L`/`H`, `SUPER+=`/`-`, `SUPER+[`/`]`,
  `SUPER+0`.
