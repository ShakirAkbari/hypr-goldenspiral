# Contributing

Small project, informal process. Issues and PRs welcome.

## Ground rules

- The layout ships as a **single file**, `goldenspiral.lua`, with no runtime
  dependencies beyond Hyprland's Lua config API. Keep it that way.
- `slots(area, n)` must stay a **pure function** (work area + count in, slot
  rectangles out). All state lives in the `state` table; all state changes go
  through `layout_msg`. This is what keeps the geometry testable.
- Match the existing comment density and style. The header block is the spec;
  update it when behaviour changes, and add a `CHANGELOG.md` entry.
- Plain ASCII punctuation in prose and comments: no em or en dashes (use `-`,
  `,`, `:` or `(...)`). CI enforces this via `tests/no-fancy-dashes.sh`.

## Tests

`tests/geometry_spec.lua` mocks `hl` / `o`, loads the layout, and checks the
placement logic (ranking, `promote`, `swapnext`, new-window-takes-mainstage,
row-wrap). Run it with any Lua 5.x:

```sh
lua tests/geometry_spec.lua
```

Add a case there for any geometry or ordering change.

`tests/no-fancy-dashes.sh` is the other CI check: it fails if a tracked file
picks up an em or en dash.

## Manual check

```sh
cp goldenspiral.lua ~/.config/hypr/hypr/goldenspiral.lua
hyprctl reload
hyprctl configerrors        # must be empty
```

Then open 2, 5, and 10+ windows on a scratch workspace and confirm the C forms,
the bottom strip wraps, and `SUPER+M` promotes the focused window.

## Attribution

The design is Shakir Akbari's (see `docs/DESIGN.md`). Please keep the credit
lines in the file header and `README.md` intact.
