-- Plain-Lua unit tests for goldenspiral.lua placement logic.
-- Run:  lua tests/geometry_spec.lua      (any Lua 5.x)
--
-- Mocks the `hl` / `o` config globals, loads the layout file, then drives its
-- recalculate / layout_msg with a fake ctx and asserts on the boxes it places.

------------------------------------------------------------------ locate the layout
local function exists(p)
  local f = io.open(p, "r"); if f then f:close() return true end
end
local DIR = (arg[0] or ""):match("^(.*)[/\\]") or "."
local LAYOUT
for _, p in ipairs({ DIR .. "/../goldenspiral.lua", DIR .. "/goldenspiral.lua",
                     "./goldenspiral.lua", "../goldenspiral.lua" }) do
  if exists(p) then LAYOUT = p break end
end
assert(LAYOUT, "cannot find goldenspiral.lua relative to " .. DIR)

------------------------------------------------------------------ mock config API
_G.REG = nil
_G.hl = {
  layout = { register = function(_, tbl) _G.REG = tbl end },
  config = function() end,
  dsp = { layout = function(s) return { msg = s } end },
  window_rule = function() end,
  exec_cmd = function() end,
}
_G.o = { bind = function() end }
_G.GOLDENSPIRAL_TEST = true -- read_bar_cfg() is a no-op; bar keeps its defaults

dofile(LAYOUT)
local L = assert(_G.REG, "layout did not register")

------------------------------------------------------------------ helpers
local AREA = { x = 0, y = 0, w = 3440, h = 1400 }

-- ids: list of stable_ids in the order Hyprland would hand back targets
-- (creation order). active: the stable_id that is focused, or nil.
local function ctx(ids, active)
  local targets = {}
  for i, id in ipairs(ids) do
    targets[i] = {
      index = i,
      window = { stable_id = id, active = (id == active) },
      placed = nil,
      place = function(self, box) self.placed = box end,
    }
  end
  return { area = AREA, targets = targets }
end

local function box_of(c, id)
  for _, t in ipairs(c.targets) do
    if t.window.stable_id == id then return t.placed end
  end
end

-- rank 1 (mainstage) is the tile touching the top-right corner of the area.
local function mainstage_id(c)
  for _, t in ipairs(c.targets) do
    local b = t.placed
    if b and b.y <= AREA.y + 1 and math.abs((b.x + b.w) - (AREA.x + AREA.w)) < 1
       and b.x > AREA.x + 1 then
      return t.window.stable_id
    end
  end
end

local fails = 0
local function check(name, cond)
  io.write(cond and "  ok   " or "  FAIL ", name, "\n")
  if not cond then fails = fails + 1 end
end

------------------------------------------------------------------ tests

-- 1. five windows, newest (5) becomes the mainstage
do
  local c = ctx({ 1, 2, 3, 4, 5 }, 5)
  L.recalculate(c)
  check("5 windows: newest is mainstage", mainstage_id(c) == 5)
  check("5 windows: id 1 is a bottom-strip tile (y in the bottom band)",
    box_of(c, 1).y > AREA.h * 0.6)
  check("5 windows: id 4 is top of left column", box_of(c, 4).x < 1 and box_of(c, 4).y < 1)
end

-- 2. promote a mid window to the mainstage
do
  local c = ctx({ 1, 2, 3, 4, 5 }, 2)
  L.recalculate(c)             -- order becomes {5,4,3,2,1}
  L.layout_msg(c, "promote")   -- focused id 2 -> rank 1
  L.recalculate(c)
  check("promote: focused window becomes mainstage", mainstage_id(c) == 2)
  check("promote: old mainstage (5) moved into left column", box_of(c, 5).x < 1)
end

-- 3. swapnext moves the focused window one slot down the C
do
  local c = ctx({ 1, 2, 3, 4, 5 }, nil)
  L.recalculate(c)                       -- order {5,4,3,2,1}
  for _, t in ipairs(c.targets) do t.window.active = (t.window.stable_id == 4) end
  local before = box_of(c, 4)
  L.layout_msg(c, "swapnext")            -- 4 (rank 2) <-> 3 (rank 3)
  L.recalculate(c)
  check("swapnext: focused window changed slot", box_of(c, 4).y ~= before.y)
  check("swapnext: neighbour took the vacated slot", box_of(c, 3).y == before.y
    or box_of(c, 3).x == before.x)
end

-- 4. opening a new window promotes it to the mainstage
do
  local c1 = ctx({ 1, 2, 3, 4, 5 }, nil)
  L.recalculate(c1)
  local c2 = ctx({ 1, 2, 3, 4, 5, 6 }, nil)
  L.recalculate(c2)
  check("new window takes the mainstage", mainstage_id(c2) == 6)
end

-- 5. bottom strip wraps to rows instead of shrinking past the minimum
do
  local c = ctx({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 }, nil)
  L.recalculate(c)
  local minw = math.huge
  local rows = {}
  for _, t in ipairs(c.targets) do
    local b = t.placed
    if b and b.x > 1 and b.y > AREA.h * 0.3 then   -- a strip tile
      minw = math.min(minw, b.w)
      rows[math.floor(b.y)] = true
    end
  end
  local nrows = 0
  for _ in pairs(rows) do nrows = nrows + 1 end
  check("14 windows: strip tiles respect the min width", minw >= AREA.w * 0.16 - 1)
  check("14 windows: strip wrapped into multiple rows", nrows >= 2)
end

-- 6. two windows: mainstage full height, one left tile
do
  local c = ctx({ 1, 2 }, nil)
  L.recalculate(c)
  check("2 windows: mainstage is full height", box_of(c, 2).h >= AREA.h - 1)
  check("2 windows: other window fills the left column", box_of(c, 1).h >= AREA.h - 1)
end

-- ctx builder for the drag tests. Each spec is a bare id, or a table
-- { id, at = {x,y}, size = {x,y} } to pin a window's reported geometry
-- (used to stand in for a drop location). place() writes at/size back, like
-- Hyprland moving the window to its tile.
local function mctx(specs)
  local targets = {}
  for i, s in ipairs(specs) do
    local tbl = type(s) == "table"
    local t = {
      index  = i,
      window = {
        stable_id = tbl and s.id or s, active = false,
        at   = tbl and s.at   or { x = 0, y = 0 },
        size = tbl and s.size or { x = 100, y = 100 },
      },
    }
    t.place = function(self, box)
      self.placed      = box
      self.window.at   = { x = box.x, y = box.y }
      self.window.size = { x = box.w, y = box.h }
    end
    targets[i] = t
  end
  return { area = AREA, targets = targets }
end

-- Simulate a full drag: recalc with every window, then a pick-up recalc with
-- the dragged one gone (Hyprland floats it), then a drop recalc where it
-- returns as the LAST target with its geometry pinned to (cx,cy). Returns the
-- post-drop ctx.
local function drag_drop(ids, drag_id, cx, cy, w, h)
  w, h = w or 360, h or 240
  L.recalculate(mctx(ids))                              -- establish order + seen
  local rest = {}
  for _, id in ipairs(ids) do
    if id ~= drag_id then rest[#rest + 1] = id end
  end
  L.recalculate(mctx(rest))                             -- pick up: window floats
  local dropped = {}
  for _, id in ipairs(rest) do dropped[#dropped + 1] = id end
  dropped[#dropped + 1] =
    { id = drag_id, at = { x = cx - w / 2, y = cy - h / 2 }, size = { x = w, y = h } }
  local c = mctx(dropped)
  L.recalculate(c)                                      -- drop
  return c
end

-- 7. drop in the MAIN zone -> mainstage. Fresh high ids so the starting order
-- is deterministic whatever earlier tests left in state.order.
do
  local c = drag_drop({ 21, 22, 23, 24, 25 }, 21, AREA.w * 0.7, AREA.h * 0.3)
  check("main-zone drop: dropped window took the mainstage", mainstage_id(c) == 21)
  check("main-zone drop: old mainstage (25) moved into the left column",
    box_of(c, 25).x < 1)
end

-- 8. drop in the SIDE zone -> front of the left column (rank 2), whatever the
-- vertical position.
do
  local c = drag_drop({ 31, 32, 33, 34, 35 }, 31, AREA.w * 0.08, AREA.h * 0.85)
  local b = box_of(c, 31)
  check("side-zone drop: window is in the left column", b.x < 1)
  check("side-zone drop: it took the TOP slot (2a), not where it was released",
    b.y < 1)
  check("side-zone drop: mainstage untouched", mainstage_id(c) == 35)
end

-- 9. drop in the BOTTOM zone -> first strip slot, no fine guess
do
  local c = drag_drop({ 41, 42, 43, 44, 45, 46, 47 }, 47, AREA.w * 0.9, AREA.h * 0.97)
  local strip_x0 = AREA.w * 0.382
  local b = box_of(c, 47)
  check("bottom-zone drop: window is a strip tile", b.y > AREA.h * 0.5)
  check("bottom-zone drop: it took the first strip column",
    math.abs(b.x - strip_x0) < 2)
end

-- 10. with drag_snap off, a dropped window behaves like any new one (mainstage)
do
  L.layout_msg(mctx({ 1 }), "dragsnap")     -- toggle off
  local c = drag_drop({ 61, 62, 63, 64, 65 }, 61, AREA.w * 0.08, AREA.h * 0.5)
  check("dragsnap off: dropped window goes to the mainstage", mainstage_id(c) == 61)
  L.layout_msg(mctx({ 1 }), "dragsnap")     -- back on for any later runs
end

------------------------------------------------------------------ the pinned app bar

local BAR_CLASS = "org.goldenspiral.chronobar"
local BAR_H = 150

-- ctx with a chronobar target appended (Hyprland hands it back like any tile).
local function ctx_bar(ids, active)
  local c = ctx(ids, active)
  local i = #c.targets + 1
  c.targets[i] = {
    index = i,
    window = { stable_id = "BAR", class = BAR_CLASS },
    placed = nil,
    place = function(self, box) self.placed = box end,
  }
  return c
end

-- 11. the bar is pinned to the bottom-right corner at its configured size.
-- Fresh ids 51..55 -> order {55,54,53,52,51}: ranks map 55,54,53,52,51.
do
  local c = ctx_bar({ 51, 52, 53, 54, 55 }, 55)
  L.recalculate(c)
  local b = box_of(c, "BAR")
  check("bar: placed", b ~= nil)
  check("bar: width is w_frac of the area", math.abs(b.w - AREA.w * 0.3333) < 2)
  check("bar: height is h_px", b.h == BAR_H)
  check("bar: hugs the right edge", math.abs((b.x + b.w) - (AREA.x + AREA.w)) < 1)
  check("bar: hugs the bottom edge", math.abs((b.y + b.h) - (AREA.y + AREA.h)) < 1)
end

-- 12. the strip runs to the floor beside the bar and stops above it over the
-- bar; the mainstage lifts above the strip; the bottom-left box keeps full
-- height.
do
  local c = ctx_bar({ 51, 52, 53, 54, 55 }, 55)
  L.recalculate(c)
  local floor = AREA.y + AREA.h
  local main = box_of(c, 55)    -- rank 1
  local bl = box_of(c, 53)      -- rank 3, bottom-left box
  local s1 = box_of(c, 52)      -- rank 4, first strip column (left of the bar)
  local s2 = box_of(c, 51)      -- rank 5, next strip column (over the bar)
  check("bar carve: first strip column runs to the floor beside the bar",
    s1.y + s1.h >= floor - 1)
  check("bar carve: the strip column over the bar stops above it",
    s2.y + s2.h <= floor - BAR_H + 1)
  check("bar carve: mainstage bottom is above the strip band",
    main.y + main.h <= floor - BAR_H + 1)
  check("bar carve: bottom-left box still reaches the area floor",
    bl.y + bl.h >= floor - 1)
  check("bar carve: rank 2 is the top-left box (touches the top-left corner)",
    box_of(c, 54).x < 1 and box_of(c, 54).y < 1)
end

-- 13. no bar target -> the layout still places everything (regression guard)
do
  local c = ctx({ 51, 52, 53, 54, 55 }, 55)
  L.recalculate(c)
  check("no bar: strip still reaches the work-area floor",
    box_of(c, 52).y + box_of(c, 52).h >= AREA.y + AREA.h - 1)
  check("no bar: rank 2 is the top-left box",
    box_of(c, 54).x < 1 and box_of(c, 54).y < 1)
end

------------------------------------------------------------------ result
print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
