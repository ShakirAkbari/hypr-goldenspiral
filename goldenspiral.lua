-- GOLDEN-SPIRAL / C-WRAP LAYOUT
--
-- Concept, layout geometry and interaction model designed by Shakir Akbari.
-- Lua implementation written with Claude Code. MIT licensed.
-- Project: https://github.com/ShakirAkbari/hypr-goldenspiral
--
-- Fixed-slot tiling. The mainstage is the big tile on the center-right; older
-- windows form a C that hugs the mainstage's left edge and its bottom edge.
-- A new window takes the mainstage and pushes everyone else one slot down the
-- C. The order is tracked explicitly, so windows can be re-ranked at runtime
-- (promote to mainstage, shuffle along the C, or drag a window and drop it in
-- another zone). The whole layout reflows on every add/remove/re-rank.
--
-- Companion app bar (bar/chronobar.py): a normal window recognised by class,
-- pinned to a fixed slot in the bottom-right corner and kept out of the C; the
-- other windows lay out around it (see the `bar` block in `state` and
-- `bar_geometry` / the `carve` argument to `slots`).
--
-- Drag-and-drop: Hyprland's Lua layout API has no drag hook. A drag pick-up
-- floats the window, so on drop it comes back as a fresh target -- and any
-- stable_id we've placed before is treated as a returning drop rather than a
-- new window. It goes to the FRONT of whichever of three zones it was dropped
-- in: MAIN (the mainstage) -> rank 1, SIDE (the left column) -> rank 2,
-- BOTTOM (the strip) -> first strip slot. No finer aim than the zone.
-- Toggle with the `dragsnap` msg.
--
-- Slots, in rank order (1 = mainstage):
--   1        mainstage             right ~62% wide; full height until a strip
--                                  forms, then it stops above the strip
--   2        left column, top      ) always exactly these two; rank 2 is always
--   3        left column, bottom   ) the upper one, and they keep full height
--   4..N     bottom strip under the mainstage: tall tiles down to the work-area
--            floor, filling left to right then wrapping upward. Tiles over the
--            app bar's corner stop above it.
--
-- The bottom-strip tiles are the minimum window size; past that the strip wraps
-- into more rows instead of shrinking tiles further.
--
-- Custom-layout API: https://wiki.hypr.land/Configuring/Layouts/Custom-Layouts/

local state = {
  left_frac   = 0.382, -- left column width as a fraction of the work area
  bottom_frac = 0.34,  -- bottom-strip band height as a fraction of the work area
  left_split  = 0.66,  -- top-left box's share of the left column height when
                       -- there is no strip (n == 3); with a strip the split
                       -- follows the mainstage bottom instead
  min_tile_w  = 0.18,  -- bottom-strip tiles never get narrower than this
                       -- (fraction of the work-area width); extra windows
                       -- wrap into more rows instead of shrinking further.
  order       = {},    -- list of window stable_ids, order[1] = mainstage
  seen        = {},    -- every stable_id we've ever placed. A "new" window
                       -- that's already in here is really a returning one
                       -- (dragged out and dropped back), so it's placed by
                       -- drop zone instead of being sent to the mainstage.
  drag_snap   = true,  -- honour a drag-and-drop; off = a dropped window just
                       -- goes back to the mainstage like any new window
  debug       = false, -- notify on each drop-zone placement

  -- Which workspace golden-spiral is scoped to, or "" (default) to make it
  -- the global layout on every workspace, as before. Set via `"workspace"` in
  -- ~/.config/goldenspiral/bar.json. When set, every other workspace keeps
  -- Hyprland's normal default layout and only this one workspace -- and the
  -- chronobar app bar -- uses golden-spiral.
  workspace   = "",

  -- The chronobar app bar (bar/chronobar.py). Its window is recognised by
  -- class, pinned to a fixed slot in the bottom-right corner, and kept out of
  -- the C ranking; the other windows lay out around it. w_frac and h_px are
  -- overridden by ~/.config/goldenspiral/bar.json if present so the bar renders
  -- at the size it is placed.
  bar = {
    class  = "org.goldenspiral.chronobar",
    w_frac = 0.3333,
    h_px   = 150,
    cmd    = "goldenspiral-bar",
  },
}

-- Pull barWidthFraction / barHeight out of ~/.config/goldenspiral/bar.json.
-- A tiny extractor, not a JSON parser: the file is a flat object written by the
-- bar and the installer. Missing file or keys just leave the defaults.
local function read_bar_cfg()
  if _G.GOLDENSPIRAL_TEST then
    return -- tests pin the defaults; no filesystem
  end
  local home = os.getenv("HOME") or ""
  local f = io.open(home .. "/.config/goldenspiral/bar.json", "r")
  if not f then
    return
  end
  local body = f:read("*a") or ""
  f:close()
  local wf = body:match('"barWidthFraction"%s*:%s*([0-9.]+)')
  local hp = body:match('"barHeight"%s*:%s*([0-9]+)')
  local ws = body:match('"workspace"%s*:%s*"([^"]*)"')
  if wf then
    state.bar.w_frac = math.max(0.15, math.min(0.6, tonumber(wf)))
  end
  if hp then
    state.bar.h_px = math.max(40, tonumber(hp))
  end
  if ws then
    state.workspace = ws
  end
end

local function clamp(x, lo, hi)
  return math.max(lo, math.min(hi, x))
end

local function index_of(list, value)
  for i, v in ipairs(list) do
    if v == value then
      return i
    end
  end
end

local function remove_value(list, value)
  local i = index_of(list, value)
  if i then
    table.remove(list, i)
  end
end

-- stable_id of whichever window is focused, or nil.
local function active_id(ctx)
  for _, t in ipairs(ctx.targets) do
    if t.window and t.window.active then
      return t.window.stable_id
    end
  end
end

-- Reconcile state.order with the live targets and return them in rank order,
-- plus the list of ids that just came back from a drag (to be placed by zone).
-- A genuinely new window is inserted at the front (newest first) so opening one
-- promotes it to the mainstage. A "new" id we've placed before is a returning
-- window -- a drag pick-up floats the window, so on drop Hyprland hands it back
-- as a fresh target -- and is parked at the end for the caller to zone-place.
local function ranked(ctx)
  local by_id, present = {}, {}
  local bar_target
  for _, t in ipairs(ctx.targets) do
    local w = t.window
    if w and w.class == state.bar.class then
      bar_target = t                 -- pinned separately, never in the C
    elseif w then
      by_id[w.stable_id] = t
      present[w.stable_id] = true
    end
  end

  -- drop windows that are gone
  local kept = {}
  for _, id in ipairs(state.order) do
    if present[id] then
      kept[#kept + 1] = id
    end
  end
  state.order = kept

  local known = {}
  for _, id in ipairs(state.order) do
    known[id] = true
  end

  -- split unranked windows into genuinely new and returning-from-a-drag
  local fresh, returning = {}, {}
  for id in pairs(present) do
    if not known[id] then
      if state.seen[id] and state.drag_snap then
        returning[#returning + 1] = id
      else
        fresh[#fresh + 1] = id
      end
    end
  end

  -- new windows: oldest first, so repeated front-insertion leaves newest at 1
  table.sort(fresh, function(a, b)
    return a < b
  end)
  for _, id in ipairs(fresh) do
    table.insert(state.order, 1, id)
  end
  -- returning windows: park at the end; recalculate() moves them to their zone
  for _, id in ipairs(returning) do
    state.order[#state.order + 1] = id
  end

  -- materialise targets in rank order
  local out = {}
  for _, id in ipairs(state.order) do
    out[#out + 1] = by_id[id]
  end
  -- windowless targets (e.g. groups) go last
  for _, t in ipairs(ctx.targets) do
    if not t.window then
      out[#out + 1] = t
    end
  end
  return out, returning, bar_target
end

-- Build N boxes in rank order for the work area `a` = {x, y, w, h}.
--
--   rank 1        mainstage, big, on the right
--   rank 2        top-left box     ) the left column, always exactly these two,
--   rank 3        bottom-left box  ) rank 2 always the upper one
--   rank 4..      bottom strip under the mainstage: tall tiles that run down to
--                 the work-area floor, filling left to right then wrapping
--                 upward. The left column is never part of the strip and keeps
--                 full height.
--
-- `carve` (optional, from bar_geometry) is the pinned app bar's footprint:
--   carve.bar_w / carve.bar_h  its size, in the bottom-right corner
-- Only the bottom-row strip tiles whose x-range is over the bar are shortened
-- to stop above it; everything else ignores the bar (it floats over the
-- mainstage corner while there is no strip).
local function slots(a, n, carve)
  local X, Y, W, H = a.x, a.y, a.w, a.h
  carve = carve or {}
  local bar_w = carve.bar_w or 0
  local bar_h = carve.bar_h or 0

  local LW = W * state.left_frac       -- left column width
  local MW = W - LW                    -- mainstage / bottom-strip width
  local out = {}

  -- The left column: two boxes (or one, at n == 2), rank 2 on top. When there
  -- is a strip, `split_y` is its top edge, so the top-left box lines up with
  -- (and is as tall as) the mainstage and the bottom-left box lines up with the
  -- strip band.
  local function left_column(split_y)
    if n < 2 then
      return
    end
    if split_y then
      out[2] = { x = X, y = Y,       w = LW, h = split_y - Y }
      out[3] = { x = X, y = split_y, w = LW, h = (Y + H) - split_y }
    else
      out[2] = { x = X, y = Y, w = LW, h = H }
    end
  end

  local n_strip = n - 3
  if n_strip < 1 then
    -- No strip yet: the mainstage takes the whole right side, stopping above
    -- the app bar if there is one. The left column splits at left_split.
    out[1] = { x = X + LW, y = Y, w = MW, h = H - bar_h }
    left_column(n >= 3 and (Y + H * state.left_split) or nil)
    return out
  end

  -- Bottom strip. Equal columns; once a tile would fall below min_tile_w it
  -- wraps into another row (growing upward, shrinking the mainstage).
  local max_cols = math.max(1, math.floor(MW / (W * state.min_tile_w)))
  local cols = math.min(n_strip, max_cols)
  local rows = math.ceil(n_strip / cols)
  local main_min = H * 0.28
  local sh = H * state.bottom_frac
  if sh * rows > H - main_min then
    sh = (H - main_min) / rows          -- keep the mainstage usable
  end
  local band = sh * rows
  local strip_top = Y + (H - band)

  out[1] = { x = X + LW, y = Y, w = MW, h = strip_top - Y }
  left_column(strip_top)

  -- The bottom row is an L: columns left of the bar run to the work-area floor,
  -- columns over the bar stop at its top edge. A column edge is snapped to the
  -- bar's left edge so nothing overlaps the bar. Columns are split between the
  -- two regions in proportion to their width, so the wider "over the bar"
  -- region gets its share (with the defaults, two columns to the left's one).
  local bar_left = X + W - bar_w
  local left_w = bar_left - (X + LW)
  local has_bar = bar_h > 0 and left_w > W * state.min_tile_w
  local left_cols, right_cols = cols, 0
  if has_bar then
    right_cols = math.min(cols - 1, math.max(1, math.floor(cols * bar_w / MW + 0.5)))
    left_cols = cols - right_cols
  end

  for k = 1, n_strip do
    local row = math.floor((k - 1) / cols)   -- 0 = bottom row, fills first
    local idx = (k - 1) % cols
    local tx, tw, th
    local base_y = strip_top + (rows - 1 - row) * sh

    if row == 0 and has_bar and idx >= left_cols then
      local j = idx - left_cols
      tw = bar_w / math.max(1, right_cols)
      tx = bar_left + j * tw
      th = sh - bar_h                        -- this column is over the app bar
    elseif row == 0 and has_bar then
      tw = left_w / left_cols
      tx = X + LW + idx * tw
      th = sh                                -- runs to the floor beside the bar
    else
      tw = MW / cols
      tx = X + LW + idx * tw
      th = (row == 0 and bar_h > 0) and (sh - bar_h) or sh
    end

    out[3 + k] = { x = tx, y = base_y, w = tw, h = th }
  end

  return out
end

-- The bar's pinned box (bottom-right corner) and its footprint, for area `a`.
local function bar_geometry(a)
  local bw = math.floor(a.w * state.bar.w_frac)
  local bh = math.min(state.bar.h_px, math.floor(a.h * 0.5))
  local box = { x = a.x + a.w - bw, y = a.y + a.h - bh, w = bw, h = bh }
  return box, { bar_w = bw, bar_h = bh }
end

-- The layout is three drop zones: MAIN (the mainstage, top-right), SIDE (the
-- whole left column) and BOTTOM (the strip under the mainstage). A window
-- dropped in a zone goes to the *front* of that zone -- rank 1, rank 2, or the
-- first strip slot -- no finer aim than that. Derived from the slot boxes so
-- it always matches the real geometry.
local function zone_rank(area, boxes, n, x, y)
  local left_edge = boxes[1].x            -- mainstage x = end of the left column
  if n >= 2 and x < left_edge then
    return 2                              -- SIDE  -> front of the left column
  end
  if n >= 4 and boxes[4] and y >= boxes[1].y + boxes[1].h then
    return 4                              -- BOTTOM -> first strip slot
  end
  return 1                                -- MAIN  -> mainstage
end

-- Move each returning (just-dropped) window to the front of the zone it was
-- released in. Returns true if state.order changed.
local function place_returning(returning, area, boxes, targets_by_id, n)
  local changed = false
  for _, id in ipairs(returning) do
    local t = targets_by_id[id]
    local w = t and t.window
    local rank
    if w and w.at and w.size then
      local cx = w.at.x + w.size.x * 0.5
      local cy = w.at.y + w.size.y * 0.5
      rank = zone_rank(area, boxes, n, cx, cy)
    else
      rank = math.min(4, n)                -- no geometry: treat as a small window
    end
    remove_value(state.order, id)
    table.insert(state.order, math.min(rank, #state.order + 1), id)
    changed = true
    if state.debug then
      pcall(function()
        hl.notification.create({
          text = string.format("goldenspiral: dropped -> rank %d", rank),
          timeout = 1500,
        })
      end)
    end
  end
  return changed
end

hl.layout.register("goldenspiral", {
  recalculate = function(ctx)
    read_bar_cfg()
    local order, returning, bar_target = ranked(ctx)
    local n = #order

    -- Pin the app bar to the bottom-right corner and carve that corner out of
    -- the area the other windows get.
    local carve
    if bar_target then
      local box, cv = bar_geometry(ctx.area)
      bar_target:place(box)
      carve = cv
    end

    if n == 0 then
      return
    end

    if n == 1 then
      -- one window: full area, the bar floats over its bottom-right corner
      order[1]:place(ctx.area)
      if order[1].window then
        state.seen[order[1].window.stable_id] = true
      end
      return
    end

    local boxes = slots(ctx.area, n, carve)

    -- send any just-dropped window to the front of its drop zone
    if #returning > 0 then
      local by_id = {}
      for _, t in ipairs(ctx.targets) do
        if t.window then
          by_id[t.window.stable_id] = t
        end
      end
      if place_returning(returning, ctx.area, boxes, by_id, n) then
        order = (ranked(ctx)) -- re-materialise in the new order
      end
    end

    for i = 1, n do
      if boxes[i] then
        order[i]:place(boxes[i])
        if order[i].window then
          state.seen[order[i].window.stable_id] = true
        end
      end
    end
  end,

  layout_msg = function(ctx, msg)
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")

    if cmd == "promote" or cmd == "mainstage" then
      -- move the focused window to the mainstage; everyone else shifts down
      local id = active_id(ctx)
      if id then
        remove_value(state.order, id)
        table.insert(state.order, 1, id)
      end
    elseif cmd == "swapnext" or cmd == "swapprev" then
      -- swap the focused window with its neighbour along the C
      local id = active_id(ctx)
      local i = id and index_of(state.order, id)
      local j = i and (i + (cmd == "swapnext" and 1 or -1))
      if i and j and j >= 1 and j <= #state.order then
        state.order[i], state.order[j] = state.order[j], state.order[i]
      end
    elseif cmd == "grow" then -- widen the mainstage
      state.left_frac = clamp(state.left_frac - 0.02, 0.2, 0.5)
    elseif cmd == "shrink" then
      state.left_frac = clamp(state.left_frac + 0.02, 0.2, 0.5)
    elseif cmd == "taller" then -- shrink the bottom strip
      state.bottom_frac = clamp(state.bottom_frac - 0.03, 0.15, 0.55)
    elseif cmd == "shorter" then
      state.bottom_frac = clamp(state.bottom_frac + 0.03, 0.15, 0.55)
    elseif cmd == "reset" then
      state.left_frac, state.bottom_frac, state.left_split = 0.382, 0.34, 0.66
    elseif cmd == "leftfrac" then
      state.left_frac = clamp(tonumber(arg) or state.left_frac, 0.2, 0.5)
    elseif cmd == "dragsnap" then -- toggle drag-and-drop re-ranking
      state.drag_snap = not state.drag_snap
    elseif cmd == "debug" then
      state.debug = not state.debug
    else
      return "goldenspiral: expected promote, swapnext, swapprev, grow, shrink, "
        .. "taller, shorter, reset, leftfrac <0.2..0.5>, dragsnap, or debug"
    end

    return true
  end,
})

-- Make it the active layout. If `workspace` is set (via
-- ~/.config/goldenspiral/bar.json), golden-spiral is scoped to that one
-- workspace only and every other workspace keeps Hyprland's normal default
-- layout; empty (the default for every other goldenspiral user) makes it
-- global, as before.
read_bar_cfg()
if state.workspace ~= "" then
  hl.workspace_rule({ workspace = state.workspace, layout = "lua:goldenspiral" })
else
  hl.config({
    general = {
      layout = "lua:goldenspiral",
    },
  })
end

-- Controls. hl.dsp.layout(msg) sends the string to this layout's layout_msg
-- (the same path Omarchy uses for hl.dsp.layout("togglesplit")).
o.bind("SUPER + M", "Spiral: promote focused to mainstage", hl.dsp.layout("promote"))
o.bind("SUPER + CTRL + DOWN", "Spiral: move window down the C", hl.dsp.layout("swapnext"))
o.bind("SUPER + CTRL + UP", "Spiral: move window up the C", hl.dsp.layout("swapprev"))
o.bind("SUPER + EQUAL", "Spiral: widen mainstage", hl.dsp.layout("grow"))
o.bind("SUPER + MINUS", "Spiral: narrow mainstage", hl.dsp.layout("shrink"))
o.bind("SUPER + BRACKETRIGHT", "Spiral: shrink bottom strip", hl.dsp.layout("taller"))
o.bind("SUPER + BRACKETLEFT", "Spiral: grow bottom strip", hl.dsp.layout("shorter"))
o.bind("SUPER + R", "Spiral: reset proportions", hl.dsp.layout("reset"))

-- The app bar (bar/chronobar.py). It is a normal tiled window that recalculate
-- pins to the corner; it must not take focus and wants no chrome of its own.
-- When golden-spiral is scoped to one workspace, the bar belongs there too --
-- pinned silently so mapping it doesn't yank focus to that workspace.
local bar_rule = {
  match = { class = state.bar.class },
  no_focus = true,
  no_shadow = true,
  border_size = 0,
  rounding = 0,
}
if state.workspace ~= "" then
  bar_rule.workspace = state.workspace .. " silent"
end
hl.window_rule(bar_rule)

-- Launch it once at session start. On a setup without hl.on, add instead:
--   exec-once = goldenspiral-bar
if type(hl.on) == "function" then
  hl.on("hyprland.start", function()
    hl.exec_cmd(state.bar.cmd)
  end)
end
