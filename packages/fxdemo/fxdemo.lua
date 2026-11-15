-- fxdemo: particle demos drawn by the video card (termina.fx, TERMINA 8.15).
--
--   fxdemo            the tour: every demo in turn, 20 s each
--   fxdemo <name>     one demo: fireworks, warp, fire, rain, comet
--   fxdemo -l         the list
--
-- Keys: Left/Right or 1-5 another demo (the tour stops), Space the demo's
-- trick, the mouse button aims (fireworks, comet), q or Esc to quit.
--
-- The card moves up to 256 particles of 8 emitters 60 times a second; the
-- program only says where they are born and how they fly. A burst reads its
-- emitter's speeds when it is born, but the colors, the size and the gravity
-- of an emitter apply to its particles alive: the fireworks fade by changing
-- their shell's colors, the warp stretches its stars by changing their size.
local term, key, sys, mouse = termina.term, termina.key, termina.sys, termina.mouse
local fx = termina.fx

if not (fx and fx.available()) then
  print("fxdemo: needs a video card that draws particles (TERMINA 8.15 or later)")
  return
end

local W, H = fx.size()
local COLS, ROWS = term.cols(), term.rows()
local CW, CH = W / COLS, H / ROWS  -- a text cell, in particle pixels
local random, floor, sqrt = math.random, math.floor, math.sqrt
local sin, cos, pi = math.sin, math.cos, math.pi

local function round(v) return floor(v + 0.5) end

-- ------------------------------------------------------------- emitters

local live = {}

local function emitter(t)
  local e, err = fx.emitter(t)
  if not e then error(err) end
  live[#live + 1] = e
  return e
end

local function removeAll()
  for _, e in ipairs(live) do e:remove() end
  live = {}
end

-- A burst of n with these speeds (pixels per second, {min, max}).
local function shoot(e, n, x, y, vx, vy)
  e:set{vx = vx, vy = vy}
  e:burst(n, round(x), round(y))
end

-- Particles with a life are born again when they die: started all at once,
-- they would come and go together forever. Their count grows over one life
-- instead, so that their births are spread out.
local function grown(count, life, since)
  if not life or life == 0 then return count end
  return math.min(count, count * since // life)
end

-- The pointer in particle pixels (the mouse counts dots of 300 x 512).
local function pointer()
  local x, y = mouse.pos()
  return x * W // 300, y * H // 512
end

-- Color ramps of the 256 (6x6x6 cube and grays), brightest first.
local RAMPS = {
  red = {196, 160, 124, 88, 52},
  gold = {226, 220, 178, 136, 94},
  green = {46, 40, 34, 28, 22},
  cyan = {51, 44, 37, 30, 23},
  blue = {75, 33, 26, 19, 17},
  magenta = {201, 164, 127, 90, 53},
  violet = {141, 98, 61, 55, 54},
  white = {231, 252, 248, 244, 240},
  orange = {214, 208, 166, 130, 94},
}
local HUES = {"red", "gold", "green", "cyan", "blue", "magenta", "violet", "white", "orange"}

local function pick(t) return t[random(#t)] end

-- ------------------------------------------------------------ fireworks

-- The card's own arithmetic (video/src/fx.cpp): 1/256 pixel per frame, 60
-- frames a second, divisions toward zero. With it, Lua knows where a rocket
-- stops rising, to the pixel, and blows it up there.
local function tdiv(a, b)
  if a < 0 then return -((-a) // b) end
  return a // b
end
local function perFrame(v) return tdiv(v * 256, 60) end
local function accel(g)
  if g == 0 then return 0 end
  return tdiv(g * 256 + (g > 0 and 3599 or -3599), 3600)
end

local fireworks = {name = "fireworks", title = "FIREWORKS",
  help = "space: volley  click: aim"}
do
  local G = 420             -- the rockets' gravity
  local rocket, trail, flash
  local shells, rockets, nextLaunch, skyline
  local Y0                   -- where rockets start: behind the roofs

  -- Explosions: speed (pixels/s), particles in n rays of per, s1 the
  -- slowest of a ray (fraction of speed): 1 a thin ring, 0 a full ball.
  local KINDS = {
    peony = {shape = "block", size = 3, life = 1800, gravity = 70, speed = 190, s1 = 0.55, n = 16, per = 3},
    ring = {shape = "block", size = 2, life = 1500, gravity = 50, speed = 210, s1 = 0.92, n = 24, per = 2},
    willow = {shape = "streak", size = 9, life = 2800, gravity = 120, speed = 140, s1 = 0.4, n = 12, per = 3,
      ramp = "gold"},
    crackle = {shape = "block", size = 3, life = 2000, gravity = 80, speed = 170, s1 = 0.25, n = 12, per = 4,
      twinkle = 140},
    palm = {shape = "streak", size = 14, life = 1500, gravity = 160, speed = 290, s1 = 0.85, n = 8, per = 2},
    strobe = {shape = "block", size = 3, life = 2200, gravity = 60, speed = 150, s1 = 0.3, n = 10, per = 3,
      twinkle = 260, ramp = "white"},
  }
  local KIND_NAMES = {"peony", "ring", "willow", "crackle", "palm", "strobe", "peony", "ring"}

  -- A shell emitter: the one free for the longest.
  local function freeShell(now)
    local best
    for _, s in ipairs(shells) do
      if not best or s.busy < best.busy then best = s end
    end
    return best
  end

  -- Colors of fade step i (1 the brightest) of a shell.
  local function colors(s, i)
    local r = RAMPS[s.ramp]
    local c = {color = r[i]}
    if s.kind.shape == "streak" then c.color2 = r[math.min(i + 2, 5)]
    elseif s.kind.twinkle then c.color2 = i < 3 and 231 or r[math.min(i + 1, 5)]
    else c.color2 = r[i] end
    return c
  end

  local function blast(now, x, y, kindName, ramp, speedScale)
    local k = KINDS[kindName]
    local s = freeShell(now)
    s.kind, s.ramp, s.t0, s.step = k, k.ramp or ramp or pick(HUES), now, 1
    s.busy = now + k.life + 100
    local t = colors(s, 1)
    t.shape, t.size, t.life, t.gravity = k.shape, k.size, k.life, k.gravity
    t.twinkle = k.twinkle or false
    s.e:set(t)
    local sp = k.speed * (speedScale or 1) * (0.85 + random() * 0.3)
    local rot = random() * pi
    for i = 0, k.n - 1 do
      local a = rot + i * 2 * pi / k.n
      local c, si = cos(a), sin(a)
      shoot(s.e, k.per, x, y, {round(c * sp * k.s1), round(c * sp)}, {round(si * sp * k.s1), round(si * sp)})
    end
    flash:burst(8, round(x), round(y))
  end

  -- A rocket from x that stops rising at height y (nil: anywhere up there).
  local function launch(now, x, y)
    y = y or random(floor(H * 0.12), floor(H * 0.45))
    local h = math.max(Y0 - y, 80)
    local v = floor(sqrt(2 * G * h))
    local vx = random(-30, 30)
    local v0, a = perFrame(-v), accel(G)
    local n = (-v0) // a  -- frames to the top
    rocket:set{vx = {vx, vx}, vy = {-v, -v}, life = (n * 1000 + 59) // 60}
    rocket:burst(1, x, Y0)
    rockets[#rockets + 1] = {t0 = now, n = n, x = x, vx = perFrame(vx), v0 = v0, a = a,
      kind = pick(KIND_NAMES), ramp = pick(HUES), double = random() < 0.2}
  end

  -- Where rocket r is after k frames, as the card moves it.
  local function at(r, k)
    return r.x + k * r.vx / 256, Y0 + (k * r.v0 + r.a * k * (k + 1) // 2) / 256
  end

  -- The city: dark blocks with lit windows on the last rows.
  local function drawSkyline()
    local x = 0
    local top = ROWS
    while x < COLS do
      local w, h = random(4, 10), random(2, 7)
      for c = x, math.min(x + w - 1, COLS - 1) do
        for r = ROWS - h, ROWS - 1 do
          local lit = c > x and c < x + w - 1 and r > ROWS - h and random() < 0.18
          term.cell(c, r, lit and 254 or 32, lit and (16 + 14) or 16)
        end
      end
      top = math.min(top, ROWS - h)
      x = x + w + random(0, 1)
    end
    return top
  end

  function fireworks.start(now)
    skyline = drawSkyline()
    Y0 = round((ROWS - 1) * CH)
    shells, rockets, nextLaunch = {}, {}, now + 300
    -- Stars, over the black only (behind the city and the text).
    emitter{count = 40, shape = "dot", y = 0, h = floor(H * 0.7), twinkle = 2600, color = 252,
      color2 = 239, behind = true, prefill = true}
    rocket = emitter{shape = "streak", size = 10, color = 230, color2 = 94, gravity = G, wobble = 1,
      wobble_ms = 120, behind = true}
    trail = emitter{shape = "block", size = 2, color = 220, color2 = 166, twinkle = 160, life = 450, vx = {-25, 25},
      vy = {10, 70}, gravity = 60, behind = true}
    flash = emitter{shape = "block", size = 3, color = 231, life = 110, vx = {-160, 160},
      vy = {-160, 160}, behind = true}
    for i = 1, 4 do
      shells[i] = {e = emitter{shape = "block", size = 2, behind = true}, busy = 0}
    end
  end

  function fireworks.tick(now)
    if now >= nextLaunch then
      launch(now, random(floor(W * 0.15), floor(W * 0.85)))
      nextLaunch = now + random(450, 1500)
    end
    for i = #rockets, 1, -1 do
      local r = rockets[i]
      local k = (now - r.t0) * 60 // 1000
      if k >= r.n then
        local x, y = at(r, r.n)
        blast(now, x, y, r.kind, r.ramp)
        if r.double then blast(now, x, y, "ring", pick(HUES), 0.55) end
        table.remove(rockets, i)
      elseif k % 2 == 0 then
        local x, y = at(r, k)
        trail:burst(1, round(x), round(y))
      end
    end
    -- Shells fade: their colors (and those of their particles) darken.
    for _, s in ipairs(shells) do
      if s.kind and s.step < 5 then
        local f = (now - s.t0) / s.kind.life
        local step = f > 0.9 and 5 or f > 0.78 and 4 or f > 0.62 and 3 or f > 0.45 and 2 or 1
        if step ~= s.step then
          s.step = step
          s.e:set(colors(s, step))
        end
      end
    end
  end

  function fireworks.action(now)  -- a volley across the sky
    for i = 1, 4 do launch(now, floor(W * (i - 0.5) / 4) + random(-30, 30)) end
    nextLaunch = now + 1800
  end

  function fireworks.click(now, x, y)
    if y < Y0 - 60 then launch(now, x, y) end
  end
end

-- ----------------------------------------------------------------- warp

local warp = {name = "warp", title = "WARP",
  help = "space: jump  c: colors  mouse: steer"}
do
  local PALETTES = {
    {near = 231, tail = 33, far = 250, farTail = 238},
    {near = 231, tail = 201, far = 219, farTail = 90},
    {near = 229, tail = 202, far = 222, farTail = 94},
    {near = 195, tail = 37, far = 159, farTail = 30},
  }
  local near, far, pal, jumpUntil, nextJump, mx, my, steerUntil, lastMove, sent

  local function speeds(q, lo, hi)
    local sx, sy = (q % 2 == 1) and 1 or -1, (q <= 2) and 1 or -1
    return {sx * lo, sx * hi}, {sy * lo, sy * hi}
  end

  local function setSpeed(jump)
    for q = 1, 4 do
      local vx, vy = speeds(q, jump and 260 or 25, jump and 1500 or 520)
      near[q]:set{vx = vx, vy = vy, size = jump and 32 or 14}
      vx, vy = speeds(q, jump and 120 or 15, jump and 700 or 200)
      far[q]:set{vx = vx, vy = vy, size = jump and 12 or 3}
    end
  end

  local function setColors()
    local p = PALETTES[pal]
    for q = 1, 4 do
      near[q]:set{color = p.near, color2 = p.tail}
      far[q]:set{color = p.far, color2 = p.farTail}
    end
  end

  function warp.start(now)
    near, far, pal = {}, {}, 1
    jumpUntil, nextJump, steerUntil, lastMove, sent = 0, now + 5000, 0, nil, 0
    for q = 1, 4 do
      far[q] = emitter{count = 30, shape = "streak", size = 3, w = 16, h = 16}
      near[q] = emitter{count = 22, shape = "streak", size = 14, w = 16, h = 16}
    end
    setSpeed(false)
    setColors()
  end

  function warp.tick(now)
    -- The center follows the pointer once it moves, else it drifts.
    local px, py = pointer()
    if lastMove and (px ~= lastMove[1] or py ~= lastMove[2]) then steerUntil = now + 4000 end
    lastMove = {px, py}
    local t = now / 1000
    local tx, ty
    if now < steerUntil then tx, ty = px, py
    else tx, ty = W / 2 + W * 0.2 * sin(t * 0.37), H / 2 + H * 0.14 * sin(t * 0.23) end
    mx = mx and mx + (tx - mx) * 0.08 or tx
    my = my and my + (ty - my) * 0.08 or ty
    if now - sent >= 60 then
      sent = now
      for q = 1, 4 do
        near[q]:set{x = round(mx) - 8, y = round(my) - 8}
        far[q]:set{x = round(mx) - 8, y = round(my) - 8}
      end
    end
    if jumpUntil > 0 and now >= jumpUntil then
      jumpUntil = 0
      setSpeed(false)
    end
    if now >= nextJump then warp.action(now) end
  end

  function warp.action(now)
    if jumpUntil > 0 then return end
    jumpUntil, nextJump = now + 1700, now + 9000
    pal = pal % #PALETTES + 1
    setColors()
    setSpeed(true)
  end

  function warp.char(now, ch)
    if ch == "c" then
      pal = pal % #PALETTES + 1
      setColors()
    end
  end
end

-- ----------------------------------------------------------------- fire

local fire = {name = "fire", title = "CAMPFIRE",
  help = "space: sparks  up/down: bigger/smaller"}
do
  local layers, sparks, cx, baseY, size, gustAt, wind, nextSparks, t0, clock

  -- Each layer: its settings at full size; count and width follow size.
  local LAYERS = {
    {count = 12, shape = "block", size = 4, color = 88, color2 = 52, twinkle = 700, life = 300,
      vx = {-15, 15}, vy = {-30, -10}, w = 260, dy = 6, h = 10},  -- coals
    {count = 30, shape = "block", size = 5, color = 230, color2 = 226, twinkle = 200, life = 650,
      vx = {-20, 20}, vy = {-260, -150}, gravity = -200, w = 110, h = 16},
    {count = 40, shape = "block", size = 4, color = 220, color2 = 214, twinkle = 260, life = 1000,
      vx = {-25, 25}, vy = {-230, -130}, gravity = -150, wobble = 4, w = 170, h = 16},
    {count = 40, shape = "block", size = 4, color = 208, color2 = 202, twinkle = 300, life = 1400,
      vx = {-30, 30}, vy = {-200, -110}, gravity = -110, wobble = 8, w = 210, h = 16},
    {count = 20, shape = "block", size = 3, color = 196, color2 = 160, twinkle = 340, life = 1800,
      vx = {-25, 25}, vy = {-170, -100}, gravity = -80, wobble = 12, w = 150, h = 16},
    {count = 20, shape = "block", size = 5, color = 239, color2 = 237, twinkle = 900, life = 3200,
      vx = {-15, 15}, vy = {-100, -60}, wobble = 24, wobble_ms = 2800, w = 110, dy = -330, h = 60},  -- smoke
    {count = 18, shape = "block", size = 2, color = 229, color2 = 214, twinkle = 120, life = 2600,
      vx = {-90, 90}, vy = {-480, -240}, gravity = 160, w = 160, h = 16},  -- embers
  }

  local function place()
    for i, l in ipairs(LAYERS) do
      local w = round(l.w * size)
      local vx = {l.vx[1] + wind, l.vx[2] + wind}
      layers[i]:set{count = grown(round(l.count * math.min(size, 1)), l.life, clock - t0), x = round(cx - w / 2), w = w,
        y = baseY + (l.dy or 0) - l.h, h = l.h, vx = vx,
        vy = {round(l.vy[1] * (0.6 + 0.4 * size)), round(l.vy[2] * (0.6 + 0.4 * size))}}
    end
  end

  -- Logs under the fire, in text.
  local function drawLogs()
    local w = 30
    local x0 = COLS // 2 - w // 2
    for c = 0, w - 1 do
      term.cell(x0 + c, ROWS - 2, c % 7 == 3 and 178 or 219, 6)
      term.cell(x0 + c, ROWS - 1, 223, 6)
    end
    for c = 3, w - 4, 6 do term.cell(x0 + c, ROWS - 3, 220, 4) end
  end

  function fire.start(now)
    layers, cx, size, wind, gustAt, nextSparks = {}, W // 2, 1, 0, 0, now + 3000
    t0, clock = now, now
    baseY = round((ROWS - 2) * CH)
    drawLogs()
    for i, l in ipairs(LAYERS) do
      local t = {}
      for k, v in pairs(l) do if k ~= "dy" then t[k] = v end end
      t.count = 0
      layers[i] = emitter(t)
    end
    sparks = emitter{shape = "block", size = 2, color = 230, color2 = 226, twinkle = 90, life = 1800,
      gravity = 380}
    place()
  end

  function fire.tick(now)
    clock = now
    if now - t0 <= 3400 then place() end  -- the counts grow
    -- Gusts: the wind turns slowly, the flames lean.
    if now >= gustAt then
      gustAt = now + 250
      local w = round(45 * sin(now / 2300) + 20 * sin(now / 700))
      if w ~= wind then
        wind = w
        place()
      end
    end
    if now >= nextSparks then
      fire.action(now, 14)
      nextSparks = now + random(2500, 6000)
    end
  end

  function fire.action(now, n)
    shoot(sparks, n or 40, cx, baseY - 20, {-260 + wind, 260 + wind}, {-650, -250})
  end

  function fire.key(now, k)
    if k == "up" then size = math.min(size + 0.15, 1.6)
    elseif k == "down" then size = math.max(size - 0.15, 0.4)
    else return end
    place()
  end
end

-- ----------------------------------------------------------------- rain

local rain = {name = "rain", title = "CODE RAIN",
  help = "space: colors"}
do
  local FONT = {
    T = {"#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."},
    E = {"#####", "#....", "#....", "####.", "#....", "#....", "#####"},
    R = {"####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"},
    M = {"#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"},
    I = {".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."},
    N = {"#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"},
    A = {".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"},
    ["8"] = {".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."},
    ["0"] = {".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."},
  }
  local PALETTES = {
    {head = 157, tail = 28, far = 22, letters = 10},
    {head = 159, tail = 30, far = 23, letters = 11},
    {head = 229, tail = 130, far = 94, letters = 14},
    {head = 219, tail = 90, far = 53, letters = 13},
  }
  local drops, mist, glints, pal, nextColors, t0

  -- Big letters of full blocks, sx columns and sy rows per font dot.
  local function big(text, row, sx, sy, attr)
    local x0 = (COLS - (#text * 6 - 1) * sx) // 2
    for i = 1, #text do
      local g = FONT[text:sub(i, i)]
      for gy = 1, 7 do
        for gx = 1, 5 do
          if g[gy]:sub(gx, gx) == "#" then
            for yy = 0, sy - 1 do
              for xx = 0, sx - 1 do
                term.cell(x0 + ((i - 1) * 6 + gx - 1) * sx + xx, row + (gy - 1) * sy + yy, 219, attr)
              end
            end
          end
        end
      end
    end
  end

  local function draw()
    local p = PALETTES[pal]
    local sx = math.max(1, COLS // 44)
    local sy = math.max(1, round(sx * CW / CH))
    local top = ROWS // 2 - 7 * sy - 2
    big("TERMINA", top, sx, sy, p.letters)
    big("80", top + 8 * sy, sx, sy, p.letters)
    local line = "8 emitters  256 particles  60 frames a second  0% of the ESP32"
    term.put((COLS - #line) // 2, top + 16 * sy + 2, line, 8)
    drops:set{color = p.head, color2 = p.tail}
    mist:set{color = p.tail, color2 = p.far}
    -- The glints are born over the letters and live there.
    local x0 = (COLS - 41 * sx) // 2
    glints:set{key = p.letters, x = round(x0 * CW), y = round(top * CH), w = round(41 * sx * CW),
      h = round(15 * sy * CH)}
  end

  function rain.start(now)
    pal, nextColors, t0 = 1, now + 7000, now
    drops = emitter{count = 90, shape = "streak", size = 20, y = -40, h = 40, vy = {300, 700},
      behind = true, prefill = true}
    mist = emitter{count = 60, shape = "streak", size = 6, y = -10, h = 10, vy = {110, 230},
      behind = true, prefill = true}
    -- Over the letters only: their color is the key.
    glints = emitter{count = 0, shape = "block", size = 3, color = 231, color2 = 159, twinkle = 300,
      life = 1200, vx = {-25, 25}, vy = {-25, 25}, behind = true}
    draw()
  end

  function rain.tick(now)
    if now - t0 <= 1300 then glints:set{count = grown(70, 1200, now - t0)} end
    if now >= nextColors then rain.action(now) end
  end

  function rain.action(now)
    pal = pal % #PALETTES + 1
    nextColors = now + 7000
    draw()
  end
end

-- ---------------------------------------------------------------- comet

local comet = {name = "comet", title = "COMET",
  help = "move the mouse: steer  click/space: supernova"}
do
  local RAINBOW = {196, 208, 226, 46, 51, 21}
  local trails, nova, head, hue, hueAt, x, y, lastMove, steerUntil

  function comet.start(now)
    trails, hue, hueAt, steerUntil, lastMove = {}, 1, now, 0, nil
    for i, c in ipairs(RAINBOW) do
      trails[i] = emitter{shape = "block", size = 3, color = c, color2 = 231, twinkle = 240,
        life = 1000, gravity = 70}
    end
    nova = emitter{shape = "streak", size = 8, color = 231, color2 = 141, life = 1600, gravity = 40}
    head = emitter{shape = "block", size = 3, color = 231, life = 120}
  end

  local function where(now)
    local px, py = pointer()
    if lastMove and (px ~= lastMove[1] or py ~= lastMove[2]) then steerUntil = now + 3000 end
    lastMove = {px, py}
    if now < steerUntil then return px, py end
    local t = now / 1000
    return W / 2 + W * 0.38 * sin(t * 1.3), H / 2 + H * 0.36 * sin(t * 0.9 + 0.6)
  end

  function comet.tick(now)
    local nx, ny = where(now)
    local dx, dy = x and nx - x or 0, y and ny - y or 0
    x, y = nx, ny
    if now >= hueAt then
      hue, hueAt = hue % #RAINBOW + 1, now + 110
    end
    -- The trail drifts away from the way the comet goes.
    local vx, vy = round(-dx * 3), round(-dy * 3)
    shoot(trails[hue], 3, x, y, {vx - 60, vx + 60}, {vy - 60, vy + 60})
    shoot(head, 1, x, y, {-20, 20}, {-20, 20})
  end

  function comet.action(now, px, py)
    px, py = px or x or W // 2, py or y or H // 2
    for i = 0, 15 do
      local a = i * pi / 8
      shoot(nova, 3, px, py, {round(cos(a) * 120), round(cos(a) * 340)}, {round(sin(a) * 120), round(sin(a) * 340)})
    end
  end

  function comet.click(now, px, py) comet.action(now, px, py) end
end

-- ----------------------------------------------------------------- main

local DEMOS = {fireworks, warp, fire, rain, comet}

if arg[1] == "-l" then
  for i, d in ipairs(DEMOS) do print(i .. "  " .. d.name) end
  return
end

local tour, idx = true, 1
if arg[1] then
  tour = false
  for i, d in ipairs(DEMOS) do
    if d.name == arg[1] or tostring(i) == arg[1] then idx = i end
  end
  if DEMOS[idx].name ~= arg[1] and tostring(idx) ~= arg[1] then
    print("fxdemo: no demo " .. arg[1] .. " (fxdemo -l lists them)")
    return
  end
end

local cur, started

local function caption()
  local text = string.format(" %d/%d %s   %s   <- ->  q", idx, #DEMOS, cur.title, cur.help)
  if tour then text = text .. "   (tour)" end
  term.put(0, 1, text:sub(1, COLS), 8)
end

local function switch(i, now)
  removeAll()
  term.cls()
  idx = (i - 1) % #DEMOS + 1
  cur = DEMOS[idx]
  cur.start(now)
  caption()
  started = now
end

term.showcursor(false)
sys.saver(false)

local ok, err = pcall(function()
  switch(idx, sys.millis())
  while true do
    local now = sys.millis()
    local e = key.poll()
    while e do
      if e.type == "key" then
        if e.key == "esc" then return end
        if e.key == "right" or e.key == "tab" then tour = false; switch(idx + 1, now)
        elseif e.key == "left" then tour = false; switch(idx - 1, now)
        elseif e.key == "space" and cur.action then cur.action(now)
        elseif cur.key then cur.key(now, e.key) end
      elseif e.type == "char" then
        local n = tonumber(e.ch)
        if e.ch == "q" or e.ch == "Q" then return
        elseif n and DEMOS[n] then tour = false; switch(n, now)
        elseif e.ch == " " and cur.action then cur.action(now)
        elseif cur.char then cur.char(now, e.ch) end
      elseif e.type == "mouse" and e.down and cur.click then
        cur.click(now, pointer())
      end
      e = key.poll()
    end
    cur.tick(now)
    if tour and now - started >= 20000 then switch(idx + 1, now) end
    sys.sleep(15)
  end
end)

removeAll()
term.cls()
term.showcursor(true)
if not ok then print("fxdemo: " .. tostring(err)) end
