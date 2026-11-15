-- skyshield: defend the city from the warheads falling on it.
--
-- Click where an interceptor should blow up: the nearest battery with
-- shots left fires it, and its explosion destroys the warheads that fly
-- into it, each one blowing up in turn (chains score more). Or move the
-- crosshair with the arrows and fire with 1, 2, 3 (left, middle, right
-- battery) or Space (the nearest). A wave ends when its warheads are
-- gone: shots and districts left are counted, the batteries reload. The
-- game ends with the last district. R plays again, Q or Esc quits.
--
-- Everything that flies is a particle of the video card (termina.fx).
-- Interceptors fly on their own: the program knows, with the card's own
-- arithmetic, where they will be. Warheads can be shot down, so the
-- program moves them itself and shows each one as a spark that lives a
-- few frames, burst again where it is every frame.
local term, key, sys, mouse = termina.term, termina.key, termina.sys, termina.mouse
local fx, sound = termina.fx, termina.sound

if not (fx and fx.available()) then
  print("skyshield: needs a video card that draws particles (TERMINA 8.15 or later)")
  return
end

local W, H = fx.size()
local COLS, ROWS = term.cols(), term.rows()
local CW, CH = W / COLS, H / ROWS  -- a text cell, in particle pixels
local random, floor, abs, sqrt, min, max = math.random, math.floor, math.abs, math.sqrt, math.min, math.max
local sin, cos, pi = math.sin, math.cos, math.pi

local function round(v) return floor(v + 0.5) end
local function clamp(v, a, b) return v < a and a or v > b and b or v end
local function beep(hz, ms) pcall(sound.tone, hz, ms) end

local GY = ROWS - 3                  -- the ground row
local GROUND = round(GY * CH)        -- its top, in pixels
local SKY_TOP = round(6 * CH)        -- below the score lines
local SHOTS = 10                     -- per battery and wave
local INTERCEPTOR = 720              -- pixels per second
local BLAST, CHAIN = 56, 30          -- explosion radii, pixels

-- The card's arithmetic (video/src/fx.cpp): 1/256 pixel per frame, 60
-- frames a second, divisions toward zero.
local function tdiv(a, b)
  if a < 0 then return -((-a) // b) end
  return a // b
end
local function perFrame(v) return tdiv(v * 256, 60) end

-- ------------------------------------------------------------ emitters

local em = {}

local function emitter(t)
  local e, err = fx.emitter(t)
  if not e then error(err) end
  return e
end

local function makeEmitters()
  em.stars = emitter{count = 14, shape = "dot", y = 0, h = GROUND - 60, twinkle = 3000, color = 250,
    color2 = 238, behind = true, prefill = true}
  em.heads = emitter{shape = "block", size = 3, color = 231, color2 = 196, twinkle = 100, life = 50}
  em.trails = emitter{shape = "block", size = 2, color = 241, color2 = 238, twinkle = 700, life = 900,
    behind = true}
  em.shots = emitter{shape = "streak", size = 10, color = 159, color2 = 31, gravity = 0}
  em.ring = emitter{shape = "block", size = 3, color = 231, color2 = 226, twinkle = 80, life = 350}
  em.glow = emitter{shape = "block", size = 3, color = 220, color2 = 202, twinkle = 140, life = 700}
  em.debris = emitter{shape = "block", size = 3, color = 208, color2 = 196, twinkle = 160, life = 1300,
    gravity = 420}
  em.smoke = emitter{shape = "block", size = 4, color = 240, color2 = 237, twinkle = 900, life = 2000,
    wobble = 10, wobble_ms = 1800}
end

local function shoot(e, n, x, y, vx, vy)
  e:set{vx = vx, vy = vy}
  e:burst(n, round(x), round(y))
end

-- ---------------------------------------------------------------- city

local G  -- the game, see newGame()

-- Three batteries and six districts along the ground.
local function layout()
  local bat = {}
  for i, c in ipairs{6, COLS // 2, COLS - 7} do
    bat[i] = {col = c, x = (c + 0.5) * CW, y = GROUND - CH, shots = SHOTS, alive = true}
  end
  local dist = {}
  local function gap(a, b)
    local w = (b - a) // 3
    for k = 0, 2 do
      local c0 = a + k * w + 1
      local cols = {}
      for c = c0, c0 + w - 3 do cols[#cols + 1] = {c = c, h = random(2, 5)} end
      dist[#dist + 1] = {c0 = c0, c1 = c0 + w - 3, x = (c0 + (w - 2) / 2) * CW, alive = true,
        cols = cols, burnAt = 0}
    end
  end
  gap(bat[1].col + 3, bat[2].col - 2)
  gap(bat[2].col + 3, bat[3].col - 2)
  return bat, dist
end

local function drawCity(now)
  for c = 0, COLS - 1 do term.cell(c, GY, 223, 8) end
  for _, d in ipairs(G.districts) do
    for _, col in ipairs(d.cols) do
      for r = 1, 5 do
        local y = GY - r
        if d.alive then
          if r <= col.h then
            local lit = (col.c * 7 + r * 3) % 5 == 0
            term.cell(col.c, y, lit and 254 or 219, lit and (3 * 16 + 14) or 3)
          else
            term.cell(col.c, y, 32, 0)
          end
        else
          -- Ruins that burn.
          if r == 1 then term.cell(col.c, y, 177, 8)
          elseif r == 2 and (col.c + now // 200) % 3 == 0 then
            term.cell(col.c, y, 30, ((col.c + now // 120) % 2 == 0) and 12 or 14)
          else term.cell(col.c, y, 32, 0) end
        end
      end
    end
  end
  for i, b in ipairs(G.batteries) do
    local a = b.alive and 15 or 8
    term.cell(b.col - 1, GY - 1, 30, a)
    term.cell(b.col, GY - 1, 30, b.alive and 11 or 8)
    term.cell(b.col + 1, GY - 1, 30, a)
    local label = b.alive and string.format(":%-2d", b.shots) or ":--"
    term.put(b.col - 1, GY + 1, tostring(i) .. label, b.shots > 3 and 7 or 12)
  end
end

-- ----------------------------------------------------------- explosions

local function radius(e, now)
  local t = now - e.t0
  if t < 350 then return e.r * t / 350 end
  if t < 650 then return e.r end
  if t < 1050 then return e.r * (1 - (t - 650) / 400) end
  return nil
end

local function explode(x, y, r, now, chain)
  G.explosions[#G.explosions + 1] = {x = x, y = y, r = r, t0 = now, chain = chain or 0}
  -- A ring that grows to r in 350 ms, then glows there until it fades.
  local n = r > 40 and 10 or 7
  local sp = r * 1000 / 350
  local rot = random() * pi
  for i = 0, n - 1 do
    local a = rot + i * 2 * pi / n
    local c, s = cos(a), sin(a)
    shoot(em.ring, 2, x, y, {round(c * sp * 0.8), round(c * sp)}, {round(s * sp * 0.8), round(s * sp)})
  end
  beep(r > 40 and 150 or 220, 40)
end

local function updateExplosions(now)
  for i = #G.explosions, 1, -1 do
    local e = G.explosions[i]
    if not e.glowing and now - e.t0 >= 350 then
      e.glowing = true
      local n = e.r > 40 and 12 or 7
      em.glow:set{vx = {-15, 15}, vy = {-15, 15}}
      for k = 0, n - 1 do
        local a = k * 2 * pi / n
        em.glow:burst(1, round(e.x + cos(a) * e.r * 0.9), round(e.y + sin(a) * e.r * 0.9))
      end
      em.glow:burst(e.r > 40 and 5 or 2, round(e.x), round(e.y))
    end
    if not radius(e, now) then table.remove(G.explosions, i) end
  end
end

-- -------------------------------------------------------- interceptors

local function fire(b, tx, ty, now)
  if not b or not b.alive or b.shots == 0 then return false end
  ty = min(ty, GROUND - 3 * CH)
  b.shots = b.shots - 1
  local dx, dy = tx - b.x, ty - b.y
  local n = max(1, math.ceil(sqrt(dx * dx + dy * dy) / (INTERCEPTOR / 60)))  -- frames
  local vx, vy = round(dx * 60 / n), round(dy * 60 / n)
  em.shots:set{vx = {vx, vx}, vy = {vy, vy}, life = (n * 1000 + 59) // 60}
  em.shots:burst(1, round(b.x), round(b.y))
  -- Where the card will have it after n frames.
  local ex, ey = b.x + n * perFrame(vx) / 256, b.y + n * perFrame(vy) / 256
  G.shots[#G.shots + 1] = {at = now + n * 1000 / 60, x = ex, y = ey, x0 = b.x, y0 = b.y, t0 = now,
    n = n}
  beep(900, 15)
  return true
end

local function nearest(tx)
  local best, bd
  for _, b in ipairs(G.batteries) do
    if b.alive and b.shots > 0 then
      local d = abs(b.x - tx)
      if not bd or d < bd then best, bd = b, d end
    end
  end
  return best
end

local function updateShots(now)
  for i = #G.shots, 1, -1 do
    local s = G.shots[i]
    if now >= s.at then
      explode(s.x, s.y, BLAST, now)
      table.remove(G.shots, i)
    elseif G.tick % 4 == 0 then
      local f = (now - s.t0) / (s.at - s.t0)
      em.trails:burst(1, round(s.x0 + (s.x - s.x0) * f), round(s.y0 + (s.y - s.y0) * f))
    end
  end
end

-- ------------------------------------------------------------- warheads

local function targets()
  local t = {}
  for _, d in ipairs(G.districts) do if d.alive then t[#t + 1] = {kind = "district", it = d, x = d.x} end end
  for _, b in ipairs(G.batteries) do if b.alive then t[#t + 1] = {kind = "battery", it = b, x = b.x} end end
  return t
end

local function launch(x, y, now, split)
  local all = targets()
  if #all == 0 then return end
  local t = all[random(#all)]
  local tx, ty = t.x + random(-12, 12), GROUND - 2 * CH
  local dx, dy = tx - x, ty - y
  local len = sqrt(dx * dx + dy * dy)
  local w = {x0 = x, y0 = y, dx = dx / len, dy = dy / len, len = len, t0 = now, speed = G.speed,
    target = t, x = x, y = y}
  if not split and G.wave >= 3 and random() < min(0.45, 0.1 * (G.wave - 2)) then
    w.splitY = random(round(H * 0.3), round(H * 0.5))
  end
  G.warheads[#G.warheads + 1] = w
end

local function hit(w, now)
  local t = w.target
  shoot(em.debris, 24, w.x, GROUND - CH, {-160, 160}, {-420, -120})
  beep(60, 220)
  if t.it.alive then
    t.it.alive = false
    if t.kind == "battery" then t.it.shots = 0 end
  end
  if t.kind == "district" then
    local left = 0
    for _, d in ipairs(G.districts) do if d.alive then left = left + 1 end end
    if left == 0 then G.over = now end
  end
end

local function updateWarheads(now)
  for i = #G.warheads, 1, -1 do
    local w = G.warheads[i]
    local d = (now - w.t0) / 1000 * w.speed
    w.x, w.y = w.x0 + w.dx * d, w.y0 + w.dy * d
    local gone = false
    -- Into an explosion: it blows up too.
    for _, e in ipairs(G.explosions) do
      local r = radius(e, now)
      if r and (w.x - e.x) ^ 2 + (w.y - e.y) ^ 2 <= r * r then
        local chain = e.chain + 1
        G.score = G.score + 25 * chain
        if chain > G.bestChain then G.bestChain = chain end
        explode(w.x, w.y, CHAIN, now, chain)
        gone = true
        break
      end
    end
    if not gone and d >= w.len then
      hit(w, now)
      gone = true
    end
    if not gone and w.splitY and w.y >= w.splitY then
      for _ = 1, random(2, 3) do launch(w.x, w.y, now, true) end
      gone = true
    end
    if gone then
      table.remove(G.warheads, i)
    else
      em.heads:burst(1, round(w.x), round(w.y))
      if G.tick % 6 == 0 then em.trails:burst(1, round(w.x), round(w.y)) end
    end
  end
end

-- ---------------------------------------------------------------- waves

local function say(text, now) G.msg, G.msgUntil = text, now + 3500 end

local function startWave(now)
  G.wave = G.wave + 1
  G.toLaunch = 6 + 2 * G.wave
  G.speed = 45 + 9 * G.wave
  G.every = max(500, 1700 - 110 * G.wave)
  G.nextLaunch = now + 2000
  for _, b in ipairs(G.batteries) do
    b.alive, b.shots = true, SHOTS
  end
  say(string.format("Wave %d: %d warheads", G.wave, G.toLaunch), now)
end

local function endWave(now)
  local shots, alive = 0, 0
  for _, b in ipairs(G.batteries) do shots = shots + b.shots end
  for _, d in ipairs(G.districts) do if d.alive then alive = alive + 1 end end
  local bonus = shots * 5 + alive * 100
  G.score = G.score + bonus
  say(string.format("Wave %d cleared: %d shots and %d districts left, bonus %d", G.wave, shots, alive,
    bonus), now)
  G.pause = now + 3500
end

local function newGame(now)
  local bat, dist = layout()
  G = {batteries = bat, districts = dist, explosions = {}, shots = {}, warheads = {},
    wave = 0, score = 0, bestChain = 0, tick = 0, msg = "", msgUntil = 0,
    cx = COLS // 2, cy = ROWS // 2}
  term.cls()
  startWave(now)
end

local function update(now)
  G.tick = G.tick + 1
  if G.pause then
    if now >= G.pause then
      G.pause = nil
      startWave(now)
    end
  elseif G.toLaunch > 0 and now >= G.nextLaunch then
    launch(random(round(W * 0.05), round(W * 0.95)), SKY_TOP, now)
    G.toLaunch = G.toLaunch - 1
    G.nextLaunch = now + random(round(G.every * 0.5), round(G.every * 1.5))
  elseif G.toLaunch == 0 and #G.warheads == 0 and #G.explosions == 0 and #G.shots == 0
      and not G.over then
    endWave(now)
  end
  updateShots(now)
  updateWarheads(now)
  updateExplosions(now)
  -- Smoke from the ruins.
  for _, d in ipairs(G.districts) do
    if not d.alive and now >= d.burnAt then
      d.burnAt = now + random(300, 700)
      shoot(em.smoke, 1, d.x + random(-15, 15), GROUND - 2 * CH, {-12, 12}, {-90, -50})
    end
  end
end

-- ---------------------------------------------------------------- draw

local function line(y, text, attr)
  local n = utf8.len(text) or #text
  if n < COLS then text = text .. string.rep(" ", COLS - n) end
  term.put(0, y, text:sub(1, COLS * 3), attr)
end

local function drawHud(now)
  line(1, string.format(" SKY SHIELD   wave %d   score %d   best chain %d", G.wave, G.score,
    G.bestChain), 15)
  line(2, now < G.msgUntil and (" " .. G.msg) or "", 14)
  line(ROWS - 1, " click: fire there   arrows + 1/2/3 or space: fire   r: restart   q: quit", 8)
end

local crossCell
local function drawCross()
  if crossCell then term.cell(crossCell[1], crossCell[2], 32, 0) end
  if G.over then crossCell = nil return end
  crossCell = {G.cx, G.cy}
  term.cell(G.cx, G.cy, 197, 11)  -- a cross
end

local function drawOver()
  local lines = {"THE CITY HAS FALLEN", string.format("Score %d   wave %d   best chain %d", G.score,
    G.wave, G.bestChain), "r: play again   q: quit"}
  for i, t in ipairs(lines) do
    term.put((COLS - #t) // 2, ROWS // 2 - 6 + i * 2, t, i == 1 and 12 or 7)
  end
end

-- ---------------------------------------------------------------- main

term.showcursor(false)
sys.saver(false)

local function pointer()
  local x, y = mouse.pos()
  return x * W // 300, y * H // 512
end

local ok, err = pcall(function()
  makeEmitters()
  local now = sys.millis()
  newGame(now)
  local drawAt = 0
  local lastCell = {mouse.cell()}
  while true do
    now = sys.millis()
    local e = key.poll()
    while e do
      if e.type == "key" then
        if e.key == "esc" then return end
        local dx = e.key == "left" and -1 or e.key == "right" and 1 or 0
        local dy = e.key == "up" and -1 or e.key == "down" and 1 or 0
        local step = e.shift and 4 or 2
        G.cx = clamp(G.cx + dx * step, 0, COLS - 1)
        G.cy = clamp(G.cy + dy * step // 2, 3, GY - 7)
      elseif e.type == "char" then
        local ch = e.ch:lower()
        local tx, ty = (G.cx + 0.5) * CW, (G.cy + 0.5) * CH
        if ch == "q" then return
        elseif ch == "r" then newGame(now)
        elseif not G.over and (ch == "1" or ch == "2" or ch == "3") then
          fire(G.batteries[tonumber(ch)], tx, ty, now)
        elseif not G.over and ch == " " then fire(nearest(tx), tx, ty, now) end
      elseif e.type == "mouse" and e.down and not G.over then
        local x, y = pointer()
        fire(nearest(x), x, y, now)
      end
      e = key.poll()
    end
    -- The crosshair follows the mouse when it moves.
    local mc, mr = mouse.cell()
    if mc ~= lastCell[1] or mr ~= lastCell[2] then
      lastCell = {mc, mr}
      G.cx, G.cy = clamp(mc, 0, COLS - 1), clamp(mr, 3, GY - 7)
    end
    if not G.over then update(now) else updateExplosions(now) end
    if now >= drawAt then
      drawAt = now + 50
      drawCity(now)
      drawHud(now)
      drawCross()
      if G.over then drawOver() end
    end
    sys.sleep(12)
  end
end)

for _, e in pairs(em) do e:remove() end
term.cls()
term.showcursor(true)
if not ok then print("skyshield: " .. tostring(err)) end
