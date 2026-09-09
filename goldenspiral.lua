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
-- (promote to mainstage, shuffle along the C, or drag a window and drop it on
-- another slot). The whole layout reflows on every add/remove/re-rank.
--
-- Drag-and-drop: Hyprland's Lua layout API has no drag hook, so this is a
-- heuristic. On a reflow where nothing was added or removed and exactly one
-- window has been carried well clear of its slot, that window is re-ranked into
-- whichever slot centre is nearest the drop point; everything between its old
-- and new rank shifts one step along the C. Toggle with the `dragsnap` msg.
--
-- Slots, in rank order (1 = mainstage):
--   1            mainstage           right ~62% wide, ~82% tall
--   2 (2a)       left column, top
--   3 (2b)       left column, middle
--   4 (2c)       left column, bottom (small)
--   5..N (3a..)  bottom strip under the mainstage, columns (wraps to rows)
--
-- 2c and the bottom-strip tiles are the minimum window size; past that the
-- strip wraps into more rows instead of shrinking tiles further.
--
-- Custom-layout API: https://wiki.hypr.land/Configuring/Layouts/Custom-Layouts/

local state = {
  left_frac   = 0.382, -- left column width as a fraction of the work area
  bottom_frac = 0.18,  -- bottom strip row height as a fraction of the work area
  top_split   = 0.41,  -- height of 2a and of 2b (2c gets the remainder)
  min_tile_w  = 0.16,  -- bottom-strip tiles never get narrower than this
                       -- (fraction of the work-area width); extra windows
                       -- wrap into more rows instead of shrinking further.
  order       = {},    -- list of window stable_ids, order[1] = mainstage
  placed      = {},    -- stable_id -> the box we last placed that window in,
                       -- so a drop can be told apart from a normal reflow
  placed_n    = 0,     -- window count at the last placement
  drag_snap   = true,  -- on drop, re-rank the window to the nearest slot
  debug       = false, -- notify on each detected drop-snap
}

-- A move counts as a drop (not jitter) once the window's centre lands at least
-- this far from where we last placed it, or 8% of the screen diagonal,
-- whichever is larger.
local DRAG_SNAP_MIN_PX  = 120
local DRAG_SNAP_MIN_FRAC = 0.08

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

-- Reconcile state.order with the live targets and return them in rank order.
-- New windows are inserted at the front (newest first) so opening a window
-- still promotes it to the mainstage.
local function ranked(ctx)
  local by_id, present = {}, {}
  for _, t in ipairs(ctx.targets) do
    local w = t.window
    if w then
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

  -- collect windows we haven't ranked yet, newest (highest id) first
  local known = {}
  for _, id in ipairs(state.order) do
    known[id] = true
  end
  local fresh = {}
  for id in pairs(present) do
    if not known[id] then
      fresh[#fresh + 1] = id
    end
  end
  -- oldest first, so repeated front-insertion leaves the newest at rank 1
  table.sort(fresh, function(a, b)
    return a < b
  end)
  for _, id in ipairs(fresh) do
    table.insert(state.order, 1, id)
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
  return out
end

-- Build N boxes in rank order for the work area `a` = {x, y, w, h}.
local function slots(a, n)
  local X, Y, W, H = a.x, a.y, a.w, a.h
  local LW = W * state.left_frac       -- left column width
  local MW = W - LW                    -- mainstage / bottom-strip width
  local BH = H * state.bottom_frac     -- bottom strip height
  local MH = H - BH                    -- mainstage height (when strip is shown)

  local out = {}

  -- Slot 1: mainstage. Full height until there's a bottom strip (>= 5 windows).
  out[1] = { x = X + LW, y = Y, w = MW, h = (n >= 5) and MH or H }

  -- Slots 2..4: left column (2a, 2b, 2c).
  if n == 2 then
    out[2] = { x = X, y = Y, w = LW, h = H }
  elseif n == 3 then
    out[2] = { x = X, y = Y,             w = LW, h = H * 0.5 }
    out[3] = { x = X, y = Y + H * 0.5,   w = LW, h = H * 0.5 }
  elseif n >= 4 then
    local h1 = H * state.top_split
    local h2 = H * state.top_split
    local h3 = H - h1 - h2
    out[2] = { x = X, y = Y,           w = LW, h = h1 }
    out[3] = { x = X, y = Y + h1,      w = LW, h = h2 }
    out[4] = { x = X, y = Y + h1 + h2, w = LW, h = h3 }
  end

  -- Slots 5..N: bottom strip under the mainstage. Equal columns, but once a
  -- tile would go below min_tile_w the strip wraps into more rows (growing
  -- upward, shrinking the mainstage) rather than shrinking the tiles further.
  local n_bottom = n - 4
  if n_bottom >= 1 then
    local max_cols = math.max(1, math.floor(MW / (W * state.min_tile_w)))
    local cols = math.min(n_bottom, max_cols)
    local rows = math.ceil(n_bottom / cols)
    local strip_h = BH * rows
    local mh = math.max(H * 0.3, H - strip_h) -- keep the mainstage usable
    local cw = MW / cols

    out[1].h = mh
    for k = 1, n_bottom do
      local r = math.floor((k - 1) / cols)
      local c = (k - 1) % cols
      out[4 + k] = {
        x = X + LW + c * cw,
        y = Y + mh + r * BH,
        w = cw,
        h = BH,
      }
    end
  end

  return out
end

local function box_center(b)
  return b.x + b.w * 0.5, b.y + b.h * 0.5
end

-- Heuristic drag-and-drop. If the id set is unchanged since the last placement
-- and exactly one window has been carried well away from its slot, treat that
-- as a drop: re-rank the window into the slot whose centre is nearest the drop
-- point, shifting everything between its old and new rank one step along the C.
-- Returns true if state.order changed.
local function apply_drop_snap(ctx, order, boxes)
  if not state.drag_snap or #order < 2 then
    return false
  end

  -- the placement baseline must cover exactly this set of windows
  local n_live = 0
  for _, t in ipairs(order) do
    if t.window then
      n_live = n_live + 1
      if not state.placed[t.window.stable_id] then
        return false
      end
    end
  end
  if n_live ~= state.placed_n then
    return false
  end

  local diag      = math.sqrt(ctx.area.w * ctx.area.w + ctx.area.h * ctx.area.h)
  local threshold = math.max(DRAG_SNAP_MIN_PX, diag * DRAG_SNAP_MIN_FRAC)

  local moved, mcx, mcy, moved_count = nil, 0, 0, 0
  for _, t in ipairs(order) do
    local w = t.window
    if w then
      local at, sz = w.at, w.size
      if not (at and sz) then
        return false -- a window without live geometry; sit this reflow out
      end
      local cx, cy = at.x + sz.x * 0.5, at.y + sz.y * 0.5
      local px, py = box_center(state.placed[w.stable_id])
      if math.sqrt((cx - px) ^ 2 + (cy - py) ^ 2) > threshold then
        moved, mcx, mcy = w.stable_id, cx, cy
        moved_count = moved_count + 1
      end
    end
  end
  if moved_count ~= 1 then
    return false
  end

  -- slot whose centre is closest to where the window was dropped
  local best_j, best_d
  for j = 1, #boxes do
    local bx, by = box_center(boxes[j])
    local d = (bx - mcx) ^ 2 + (by - mcy) ^ 2
    if not best_d or d < best_d then
      best_d, best_j = d, j
    end
  end

  local cur = index_of(state.order, moved)
  if not cur or not best_j or cur == best_j then
    return false
  end

  table.remove(state.order, cur)
  table.insert(state.order, best_j, moved)

  if state.debug then
    pcall(function()
      hl.notification.create({
        text = string.format("goldenspiral drop-snap: slot %d -> %d", cur, best_j),
        timeout = 1500,
      })
    end)
  end
  return true
end

hl.layout.register("goldenspiral", {
  recalculate = function(ctx)
    local order = ranked(ctx)
    local n = #order
    if n == 0 then
      return
    end
    if n == 1 then
      order[1]:place(ctx.area)
      state.placed = {}
      if order[1].window then
        state.placed[order[1].window.stable_id] = ctx.area
      end
      state.placed_n = n
      return
    end

    local boxes = slots(ctx.area, n)

    if apply_drop_snap(ctx, order, boxes) then
      order = ranked(ctx) -- re-materialise targets in the new rank order
    end

    state.placed = {}
    for i = 1, n do
      if boxes[i] then
        order[i]:place(boxes[i])
        if order[i].window then
          state.placed[order[i].window.stable_id] = boxes[i]
        end
      end
    end
    state.placed_n = n
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
      state.bottom_frac = clamp(state.bottom_frac - 0.02, 0.1, 0.4)
    elseif cmd == "shorter" then
      state.bottom_frac = clamp(state.bottom_frac + 0.02, 0.1, 0.4)
    elseif cmd == "reset" then
      state.left_frac, state.bottom_frac, state.top_split = 0.382, 0.18, 0.41
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

-- Make it the active layout.
hl.config({
  general = {
    layout = "lua:goldenspiral",
  },
})

-- Controls. hl.dsp.layout(msg) sends the string to this layout's layout_msg
-- (the same path Omarchy uses for hl.dsp.layout("togglesplit")).
o.bind("SUPER + M", "Spiral: promote focused to mainstage", hl.dsp.layout("promote"))
o.bind("SUPER + CTRL + DOWN", "Spiral: move window down the C", hl.dsp.layout("swapnext"))
o.bind("SUPER + CTRL + UP", "Spiral: move window up the C", hl.dsp.layout("swapprev"))
o.bind("SUPER + EQUAL", "Spiral: widen mainstage", hl.dsp.layout("grow"))
o.bind("SUPER + MINUS", "Spiral: narrow mainstage", hl.dsp.layout("shrink"))
o.bind("SUPER + BRACKETRIGHT", "Spiral: shrink bottom strip", hl.dsp.layout("taller"))
o.bind("SUPER + BRACKETLEFT", "Spiral: grow bottom strip", hl.dsp.layout("shorter"))
o.bind("SUPER + 0", "Spiral: reset proportions", hl.dsp.layout("reset"))
