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
-- (promote to mainstage, shuffle along the C). The whole layout reflows on
-- every add/remove/re-rank.
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
}

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

hl.layout.register("goldenspiral", {
  recalculate = function(ctx)
    local order = ranked(ctx)
    local n = #order
    if n == 0 then
      return
    end
    if n == 1 then
      order[1]:place(ctx.area)
      return
    end

    local boxes = slots(ctx.area, n)
    for i = 1, n do
      if boxes[i] then
        order[i]:place(boxes[i])
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
      state.bottom_frac = clamp(state.bottom_frac - 0.02, 0.1, 0.4)
    elseif cmd == "shorter" then
      state.bottom_frac = clamp(state.bottom_frac + 0.02, 0.1, 0.4)
    elseif cmd == "reset" then
      state.left_frac, state.bottom_frac, state.top_split = 0.382, 0.18, 0.41
    elseif cmd == "leftfrac" then
      state.left_frac = clamp(tonumber(arg) or state.left_frac, 0.2, 0.5)
    else
      return "goldenspiral: expected promote, swapnext, swapprev, grow, shrink, "
        .. "taller, shorter, reset, or leftfrac <0.2..0.5>"
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
o.bind("SUPER + CTRL + L", "Spiral: move window down the C", hl.dsp.layout("swapnext"))
o.bind("SUPER + CTRL + H", "Spiral: move window up the C", hl.dsp.layout("swapprev"))
o.bind("SUPER + EQUAL", "Spiral: widen mainstage", hl.dsp.layout("grow"))
o.bind("SUPER + MINUS", "Spiral: narrow mainstage", hl.dsp.layout("shrink"))
o.bind("SUPER + BRACKETRIGHT", "Spiral: shrink bottom strip", hl.dsp.layout("taller"))
o.bind("SUPER + BRACKETLEFT", "Spiral: grow bottom strip", hl.dsp.layout("shorter"))
o.bind("SUPER + 0", "Spiral: reset proportions", hl.dsp.layout("reset"))
