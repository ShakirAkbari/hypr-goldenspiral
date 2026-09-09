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

-- 7. drag-and-drop: a window carried onto another slot is re-ranked there
do
  -- ctx whose place() also updates window.at/.size, so the next recalculate
  -- sees each window where we last put it (like Hyprland does).
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

  local c = dctx({ 1, 2, 3, 4, 5 })
  L.recalculate(c)                          -- order {5,4,3,2,1}, all placed
  check("drop: 5 starts on the mainstage", mainstage_id(c) == 5)

  -- "pick up" id 1 (a bottom-strip tile) and let go over the mainstage
  for _, t in ipairs(c.targets) do
    if t.window.stable_id == 1 then
      t.window.at   = { x = AREA.w * 0.60, y = AREA.h * 0.20 }
      t.window.size = { x = 400, y = 300 }
    end
  end
  L.recalculate(c)
  check("drop: dropped window took the mainstage", mainstage_id(c) == 1)
  check("drop: old mainstage (5) shifted into the left column", box_of(c, 5).x < 1)

  -- a tiny nudge must NOT re-rank anything
  local d = dctx({ 10, 11, 12, 13, 14 })
  L.recalculate(d)
  local ms = mainstage_id(d)
  for _, t in ipairs(d.targets) do
    if t.window.stable_id == 11 then
      t.window.at = { x = t.window.at.x + 12, y = t.window.at.y + 8 }
    end
  end
  L.recalculate(d)
  check("drop: a 12px nudge does not re-rank", mainstage_id(d) == ms)
end

------------------------------------------------------------------ result
print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
