-- realm: isometric world prototype. A generated island with a village,
-- trees and people walking around. The colors and sprites come from
-- realm.art; the video card draws the world (the iso library), this
-- program only moves the camera and the people.
--
-- Arrows (or ZQSD/WASD) walk, a click walks to a tile, C switches the view
-- between jumping near the edges and following every step, Esc quits.
--
-- Copyright (c) 2026 Vendetta 84. All rights reserved. See LICENSE.

local MAP = 64
local HW, HH = 16, 8   -- half a ground diamond
local STEPS = 6        -- frames to walk one tile
local FRAME_MS = 33

-- Sprites of realm.art: 3 variants of each ground, then the objects and
-- the 3 frames of a person (standing, two walking).
local G_WATER, G_SAND, G_GRASS, G_STONE, G_DIRT = 0, 1, 2, 3, 4
local TREE, ROCK, WALL, PERSON = 15, 18, 20, 21
local NONE, MIRROR = 255, 128
-- Its colors.
local DEEP, LINE, TUNIC, TEXT, HUD_BG, PHOS = 9, 30, 33, 37, 38, 39
local TUNICS = 64      -- each person's tunic and its shade

-- ------------------------------------------------------------------ noise

local function hash3(x, y, s)
  local h = x * 374761393 + y * 668265263 + s * -2048144777
  h = (h ~ (h >> 13)) * 1274126177
  return h ~ (h >> 16)
end

local function rnd(x, y, s) return (hash3(x, y, s) & 0xFFFF) / 65535 end

local function smooth(t) return t * t * (3 - 2 * t) end

local function noise(x, y, s)
  local ix, iy = math.floor(x), math.floor(y)
  local fx, fy = smooth(x - ix), smooth(y - iy)
  local a, b = rnd(ix, iy, s), rnd(ix + 1, iy, s)
  local c, d = rnd(ix, iy + 1, s), rnd(ix + 1, iy + 1, s)
  local top = a + (b - a) * fx
  return top + (c + (d - c) * fx - top) * fy
end

-- ------------------------------------------------------------------ world

local O_NONE, O_TREE, O_ROCK, O_WALL = 0, 1, 2, 3
local ground, object, variant = {}, {}, {}

local function at(x, y) return y * MAP + x + 1 end
local function inside(x, y) return x >= 0 and y >= 0 and x < MAP and y < MAP end
local function walkable(x, y)
  return inside(x, y) and ground[at(x, y)] ~= G_WATER and object[at(x, y)] == O_NONE
end

local function paint(x0, y0, x1, y1, g)
  for y = y0, y1 do
    for x = x0, x1 do
      if inside(x, y) then
        ground[at(x, y)] = g
        object[at(x, y)] = O_NONE
      end
    end
  end
end

-- Walls around [x0, x1] x [y0, y1], open at (dx, dy).
local function house(x0, y0, x1, y1, dx, dy)
  paint(x0, y0, x1, y1, G_DIRT)
  for y = y0, y1 do
    for x = x0, x1 do
      if (x == x0 or x == x1 or y == y0 or y == y1) and not (x == dx and y == dy) then
        object[at(x, y)] = O_WALL
      end
    end
  end
end

local function generate(seed)
  local c = (MAP - 1) / 2
  for y = 0, MAP - 1 do
    for x = 0, MAP - 1 do
      local e = .55 * noise(x / 11, y / 11, seed) + .3 * noise(x / 5, y / 5, seed + 1)
        + .15 * noise(x / 2.5, y / 2.5, seed + 2)
      local dx, dy = (x - c) / c, (y - c) / c
      local r = math.sqrt(dx * dx + dy * dy)
      e = e + .45 - r * r
      if r < .3 then e = math.max(e, .5) end  -- room for the village
      local g = e < .2 and G_WATER or e < .27 and G_SAND or G_GRASS
      local i = at(x, y)
      ground[i], object[i], variant[i] = g, O_NONE, hash3(x, y, seed + 3) % 6
      if g == G_GRASS and r >= .32 then
        local forest = noise(x / 7, y / 7, seed + 4)
        local h = hash3(x, y, seed + 5) % 100
        if (forest > .52 and h < 55) or h < 3 then object[i] = O_TREE
        elseif h > 97 then object[i] = O_ROCK end
      end
    end
  end
  -- Roads to the four shores, then the square and the houses.
  local m = MAP // 2
  for i = 0, MAP - 1 do
    for w = -1, 0 do
      if ground[at(i, m + w)] ~= G_WATER then paint(i, m + w, i, m + w, G_DIRT) end
      if ground[at(m + w, i)] ~= G_WATER then paint(m + w, i, m + w, i, G_DIRT) end
    end
  end
  paint(m - 5, m - 5, m + 4, m + 4, G_STONE)
  house(m - 13, m - 12, m - 7, m - 7, m - 7, m - 9)
  house(m + 6, m - 13, m + 12, m - 8, m + 9, m - 8)
  house(m - 12, m + 6, m - 6, m + 12, m - 9, m + 6)
  house(m + 7, m + 7, m + 13, m + 11, m + 7, m + 9)
  object[at(m - 3, m - 3)], object[at(m - 3, m + 2)] = O_ROCK, O_ROCK
end

-- The map for the video card: ground sprite, object sprite per tile.
local function tiles()
  local out = {}
  for i = 1, MAP * MAP do
    local v, o = variant[i], NONE
    if object[i] == O_TREE then
      o = TREE + v % 3 + (v & 1 == 1 and MIRROR or 0)
    elseif object[i] == O_ROCK then
      o = ROCK + (v & 1)
    elseif object[i] == O_WALL then
      o = WALL
    end
    out[i] = string.char(ground[i] * 3 + v % 3, o)
  end
  return table.concat(out)
end

-- ----------------------------------------------------------------- people

local people = {}  -- the player first

local function person(name, x, y, tunic)
  return {name = name, x = x, y = y, tx = x, ty = y, step = 0, left = false,
          tunic = tunic, nextMove = 0, path = {}}
end

-- Foot point in world dots.
local function footX(p)
  local a, b = (p.x - p.y) * HW, (p.tx - p.ty) * HW
  return HW + a + (b - a) * p.step // STEPS
end
local function footY(p)
  local a, b = (p.x + p.y) * HH, (p.tx + p.ty) * HH
  return HH + a + (b - a) * p.step // STEPS
end

local function start(p, dx, dy)
  if p.step > 0 or (dx == 0 and dy == 0) or not walkable(p.x + dx, p.y + dy) then
    return false
  end
  p.tx, p.ty = p.x + dx, p.y + dy
  if dx ~= dy then p.left = dx - dy < 0 end  -- direction on the screen
  p.step = 1
  return true
end

local function advance(p)
  if p.step == 0 then return end
  p.step = p.step + 1
  if p.step > STEPS then
    p.x, p.y, p.step = p.tx, p.ty, 0
  end
end

-- Breadth-first search; p.path holds the tiles to walk, last first.
local DX = {1, -1, 0, 0, 1, -1, 1, -1}
local DY = {0, 0, 1, -1, 1, -1, -1, 1}

local function findPath(p, gx, gy)
  if not walkable(gx, gy) then return false end
  local sx, sy = p.x, p.y
  if p.step > 0 then sx, sy = p.tx, p.ty end
  local from, queue, head = {}, {sy * MAP + sx}, 1
  from[sy * MAP + sx] = sy * MAP + sx
  local goal = gy * MAP + gx
  while queue[head] and not from[goal] do
    local c = queue[head]
    head = head + 1
    local cx, cy = c % MAP, c // MAP
    for d = 1, 8 do
      local nx, ny = cx + DX[d], cy + DY[d]
      local n = ny * MAP + nx
      -- No cutting corners between two blocked tiles.
      if walkable(nx, ny) and not from[n]
          and (d <= 4 or walkable(cx + DX[d], cy) or walkable(cx, cy + DY[d])) then
        from[n] = c
        queue[#queue + 1] = n
      end
    end
  end
  if not from[goal] then return false end
  p.path = {}
  local c = goal
  while c ~= sy * MAP + sx do
    p.path[#p.path + 1] = {c % MAP, c // MAP}
    c = from[c]
  end
  return true
end

local function wander(p, now)
  if p.step > 0 or now < p.nextMove then return end
  local d = sys.random(4)
  -- Stay near home: the village square.
  local nx, ny = p.x + DX[d], p.y + DY[d]
  if math.abs(nx - MAP // 2) > 9 or math.abs(ny - MAP // 2) > 9 then
    d = d % 2 == 1 and d + 1 or d - 1
  end
  start(p, DX[d], DY[d])
  p.nextMove = now + 400 + sys.random(2200)
end

-- ----------------------------------------------------------------- screen

local W, VIEW_H = 0, 0
local camX, camY, follow = 0, 0, false

-- Keeps the player in view: recenters near the edges, or always.
local function frameCamera(force)
  local me = people[1]
  local sx, sy = footX(me) - camX, footY(me) - camY
  local out = sx < W / 5 or sx > W * 4 / 5 or sy < VIEW_H / 4 or sy > VIEW_H * 4 / 5
  if force or follow or out then
    camX, camY = footX(me) - W // 2, footY(me) - VIEW_H // 2
  end
end

local function clickTo(mx, my)
  if my >= VIEW_H then return end
  -- Inverse of the projection: a = x - y, b = x + y.
  local a, b = (mx + camX - HW) / HW, (my + camY - HH) / HH
  local x, y = math.floor((a + b) / 2 + .5), math.floor((b - a) / 2 + .5)
  if findPath(people[1], x, y) then sound.tone(880, 15) else sound.tone(220, 40) end
end

-- Direction held on the keyboard, as a map step: up on the screen is one
-- tile back on both axes.
local function heldStep()
  local sx, sy = 0, 0
  if key.held("up") or key.held("w") or key.held("z") then sy = sy - 1 end
  if key.held("down") or key.held("s") then sy = sy + 1 end
  if key.held("left") or key.held("a") or key.held("q") then sx = sx - 1 end
  if key.held("right") or key.held("d") then sx = sx + 1 end
  local function sign(v) return v > 0 and 1 or v < 0 and -1 or 0 end
  return sign(sx + sy), sign(sy - sx)
end

local ARROWS = {up = {0, -1}, down = {0, 1}, left = {-1, 0}, right = {1, 0}}

local fps = 0

local function frame()
  local list = {}
  for i, p in ipairs(people) do
    local f = 0
    if p.step > 0 then f = 1 + (p.x + p.y + p.step * 2 // STEPS) % 2 end
    list[i] = {sprite = PERSON + f, x = footX(p), y = footY(p),
               depth = math.max(p.x + p.y, p.tx + p.ty), flip = p.left,
               tunic = p.tunic, name = p.name}
  end
  local me = people[1]
  iso.frame{x = camX, y = camY, people = list, deep = DEEP, recolor = TUNIC,
            text = TEXT, line = LINE, fg = PHOS, bg = HUD_BG,
            status = string.format("VENDETTA REALM  %d,%d  %d fps  %s  Arrows/click: walk  C: view  Esc",
                                   me.x, me.y, fps, follow and "follow" or "jump")}
end

local function artFile()
  for _, p in ipairs({"/pkg/realm/realm.art", "realm.art", "/realm.art"}) do
    if fs.exists(p) then return fs.read(p) end
  end
  error("realm.art not found")
end

-- ------------------------------------------------------------------- main

local art = artFile()
generate(84)
local m = MAP // 2
local cast = {
  {"You", m, m, 0x2f7fd0}, {"Ada", m - 3, m + 1, 0xa83232}, {"Hugo", m + 2, m + 2, 0x3f8a4a},
  {"Mira", m - 1, m - 4, 0x8a3a9a}, {"Tom", m + 3, m - 2, 0xc08a2a},
}

W, VIEW_H = iso.open()
iso.load(art)
for i, c in ipairs(cast) do
  local tunic = TUNICS + 2 * (i - 1)
  people[i] = person(c[1], c[2], c[3], tunic)
  local r, g, b = c[4] >> 16, c[4] >> 8 & 0xFF, c[4] & 0xFF
  iso.color(tunic, c[4])
  iso.color(tunic + 1, (r // 2 + 8) << 16 | (g // 2 + 4) << 8 | (b // 2 + 8))
end
iso.map(MAP, MAP, tiles())
mouse.show(true)
frameCamera(true)

local last, fpsAt, frames = sys.millis(), sys.millis(), 0
local quit = false
while not quit do
  local e = key.poll()
  while e do
    local me = people[1]
    if e.type == "key" and e.key == "esc" then
      quit = true
    elseif e.type == "char" and e.ch:lower() == "c" then
      follow = not follow
      frameCamera(true)
    elseif e.type == "mouse" and e.down and e.button == 0 then
      clickTo(mouse.pos())
    elseif e.type == "key" and ARROWS[e.key] then
      -- A key press walks one tile even without held-key reports.
      local sx, sy = ARROWS[e.key][1], ARROWS[e.key][2]
      local x, y = me.x, me.y
      if me.step > 0 then x, y = me.tx, me.ty end
      me.path = {{x + sx + sy, y + sy - sx}}
    end
    e = key.poll()
  end

  local now = sys.millis()
  if now - last >= FRAME_MS then
    last = now
    local me = people[1]
    if me.step == 0 then
      local dx, dy = heldStep()
      if dx ~= 0 or dy ~= 0 then
        me.path = {}
        start(me, dx, dy)
      elseif #me.path > 0 then
        local nxt = table.remove(me.path)
        if not start(me, nxt[1] - me.x, nxt[2] - me.y) then me.path = {} end
      end
    end
    for i = 2, #people do wander(people[i], now) end
    for _, p in ipairs(people) do advance(p) end
    frameCamera(false)
    frames = frames + 1
  end
  if now - fpsAt >= 1000 then
    fps = frames * 1000 // (now - fpsAt)
    frames, fpsAt = 0, now
  end
  frame()
  sys.yield()
end
iso.close()
