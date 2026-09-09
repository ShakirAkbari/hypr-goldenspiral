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
}
_G.o = { bind = function() end }

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
  check("5 windows: id 1 is a bottom-strip tile (y in lower third)",
    box_of(c, 1).y > AREA.h * 0.66)
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

-- ctx whose place() also updates window.at/.size, so the next recalculate sees
-- each window where we last put it (like Hyprland does). Used by the drag tests.
local function dctx(ids)
  local targets = {}
  for i, id in ipairs(ids) do
    local t = {
      index  = i,
      window = { stable_id = id, active = false,
                 at = { x = -1e4, y = -1e4 }, size = { x = 100, y = 100 } },
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

-- move a window's reported geometry, as if the user dragged it there
local function drag_to(c, id, cx, cy, w, h)
  w, h = w or 360, h or 240
  for _, t in ipairs(c.targets) do
    if t.window.stable_id == id then
      t.window.at   = { x = cx - w / 2, y = cy - h / 2 }
      t.window.size = { x = w, y = h }
    end
  end
end

-- 7. drop onto a big slot: hit-tested, lands there exactly.
-- Fresh, high stable_ids so the initial rank order is deterministic regardless
-- of what earlier tests left in state.order.
do
  local c = dctx({ 21, 22, 23, 24, 25 })
  L.recalculate(c)                          -- order {25,24,23,22,21}
  check("drop on mainstage: 25 starts on the mainstage", mainstage_id(c) == 25)

  -- pick up id 21 (a bottom-strip tile) and let go over the mainstage
  drag_to(c, 21, AREA.w * 0.62, AREA.h * 0.30)
  L.recalculate(c)
  check("drop on mainstage: dropped window took the mainstage", mainstage_id(c) == 21)
  check("drop on mainstage: old mainstage (25) shifted into the left column",
    box_of(c, 25).x < 1)

  -- drop a window onto the middle of the left column (the 2b slot)
  local c2 = dctx({ 31, 32, 33, 34, 35 })
  L.recalculate(c2)                         -- order {35,34,33,32,31}
  drag_to(c2, 35, AREA.w * 0.10, AREA.h * 0.5) -- left column, vertically centred
  L.recalculate(c2)
  local b35 = box_of(c2, 35)
  check("drop on left column: window is in the left column now", b35.x < 1)
  check("drop on left column: it took the middle slot (2b)",
    b35.y > AREA.h * 0.2 and b35.y < AREA.h * 0.7)
end

-- 8. drop below the big slots: goes to the FRONT of the strip, no fine guess
do
  local c = dctx({ 41, 42, 43, 44, 45, 46, 47 })
  L.recalculate(c)                          -- order {47,46,45,44,43,42,41}
  -- ranks 5,6,7 are the strip = ids 43,42,41 across three columns
  local strip_x0 = box_of(c, 43).x         -- first strip column
  check("strip drop: 43 starts in the first strip column",
    strip_x0 > AREA.w * 0.382 - 1 and box_of(c, 43).y > AREA.h * 0.5)

  -- drag id 41 (rank 7, last strip tile) somewhere low; exact spot irrelevant
  drag_to(c, 41, AREA.w * 0.5, AREA.h * 0.97, 300, 60)
  L.recalculate(c)
  check("strip drop: dropped window is now the first strip tile",
    math.abs(box_of(c, 41).x - strip_x0) < 1 and box_of(c, 41).y > AREA.h * 0.5)
  check("strip drop: the old first strip tile (43) moved one column right",
    box_of(c, 43).x > strip_x0 + 1)
  check("strip drop: mainstage is untouched", mainstage_id(c) == 47)
end

-- 9. a tiny nudge must NOT re-rank anything
do
  local d = dctx({ 51, 52, 53, 54, 55 })
  L.recalculate(d)
  local ms = mainstage_id(d)
  for _, t in ipairs(d.targets) do
    if t.window.stable_id == 52 then
      t.window.at = { x = t.window.at.x + 12, y = t.window.at.y + 8 }
    end
  end
  L.recalculate(d)
  check("nudge: a 12px nudge does not re-rank", mainstage_id(d) == ms)
end

------------------------------------------------------------------ result
print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
