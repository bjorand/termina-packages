-- firekeeper: keep the campfire alive from 20:00 until dawn.
--
-- Wood grows in the woods at both edges of the screen, out of the light,
-- where the wolves wait. A log on weak embers smothers them: twigs first.
-- A big fire throws sparks that set the grass alight: stomp them out
-- before they reach the woods. Rain cools the fire down.
--
-- Left/Right walk (stand in the woods to gather), Space throws a log on
-- the fire, T a handful of twigs, R plays again, Q or Esc quits.
-- "firekeeper 2" plays a night of 2 minutes (5 by default).
--
-- The flames, smoke, embers, sparks, rain and stars are particles of the
-- video card (termina.fx): the fire's heat sets their counts and speeds.
local term, key, sys = termina.term, termina.key, termina.sys
local fx, sound = termina.fx, termina.sound

if not (fx and fx.available()) then
  print("firekeeper: needs a video card that draws particles (TERMINA 8.15 or later)")
  return
end

local W, H = fx.size()
local COLS, ROWS = term.cols(), term.rows()
local CW, CH = W / COLS, H / ROWS  -- a text cell, in particle pixels
local random, floor, abs, max, min = math.random, math.floor, math.abs, math.max, math.min

local function round(v) return floor(v + 0.5) end
local function clamp(v, a, b) return v < a and a or v > b and b or v end

local GY = ROWS - 5           -- the ground row
local FX = COLS // 2          -- the fire's column
local WOODS = 7               -- forest columns on each side
local NIGHT_S = 300           -- real seconds from 20:00 to 06:00
if tonumber(arg[1]) then NIGHT_S = clamp(round(tonumber(arg[1]) * 60), 30, 3600) end
local SPEED = 22              -- walking, columns per second
local MAX_LOGS, MAX_TWIGS = 3, 5
local LOG_FUEL, TWIG_FUEL = 25, 4
local BASE_Y = round((GY - 0.5) * CH)  -- where the flames are born
local CX = round((FX + 0.5) * CW)

local function beep(hz, ms) pcall(sound.tone, hz, ms) end

-- ------------------------------------------------------------ emitters

local em = {}

local function emitter(t)
  local e, err = fx.emitter(t)
  if not e then error(err) end
  return e
end

local function makeEmitters()
  em.stars = emitter{count = 25, shape = "dot", y = 0, h = round((GY - 10) * CH), twinkle = 2600,
    color = 252, color2 = 239, behind = true, prefill = true}
  em.core = emitter{shape = "block", size = 5, color = 230, color2 = 226, twinkle = 200, life = 650,
    gravity = -200}
  em.mid = emitter{shape = "block", size = 4, color = 220, color2 = 214, twinkle = 260, life = 1000,
    gravity = -150, wobble = 4}
  em.outer = emitter{shape = "block", size = 4, color = 208, color2 = 196, twinkle = 300, life = 1400,
    gravity = -110, wobble = 8}
  em.smoke = emitter{shape = "block", size = 4, color = 242, color2 = 239, twinkle = 900, life = 3200,
    wobble = 22, wobble_ms = 2800}
  em.embers = emitter{shape = "block", size = 2, color = 229, color2 = 214, twinkle = 120, life = 2600,
    gravity = 160}
  em.sparks = emitter{shape = "block", size = 2, color = 230, color2 = 208, twinkle = 90, life = 900,
    gravity = 380}
  em.rain = emitter{shape = "streak", size = 8, color = 75, color2 = 17, x = -200, y = -30,
    w = W + 400, h = 30, behind = true}
end

local function shoot(e, n, x, y, vx, vy)
  e:set{vx = vx, vy = vy}
  e:burst(n, round(x), round(y))
end

-- --------------------------------------------------------------- state

local S  -- the game: see reset()

local function say(text, now) S.msg, S.msgUntil = text, now + 4000 end

local function reset(now)
  S = {
    t0 = now, minutes = 0, state = "play", ending = nil,
    heat = 8, fuel = 30, smotherUntil = 0, kindled = -1e9,
    px = FX + 4, logs = 1, twigs = 3, lives = 3, gather = 0,
    wind = 0, windTarget = 0, windAt = now + 6000,
    rainUntil = 0, nextRain = random(100, 180),  -- game minutes
    wolves = {}, nextWolf = 60,
    fires = {}, score = 0, stomped = 0,
    msg = "Keep the fire alive until dawn. Wood grows in the woods.", msgUntil = now + 6000,
  }
  em.rain:set{count = 0}
  em.stars:set{color = 252, color2 = 239}
end

local function lightRadius() return 3 + S.heat * 0.30 end
local function nearFire() return abs(S.px - FX) <= 5 end
local function inWoods() return S.px < WOODS or S.px >= COLS - WOODS end
local function raining() return S.minutes < S.rainUntil end

local function finish(state, text)
  if S.state ~= "play" then return end
  S.state, S.ending = state, text
  if state == "won" then beep(880, 120) else beep(110, 400) end
end

-- ---------------------------------------------------------------- fire

-- The particles follow the heat (how much burns) and the fuel (how wide).
local function fireLook(now)
  local f = S.heat / 100
  local wide = 0.45 + 0.55 * min(1, S.fuel / 40)
  local up = 0.45 + 0.75 * f
  local wind = round(S.wind)
  local function layer(e, n, w, vy1, vy2, opt)
    opt = opt or {}
    w = max(8, round(w * wide))
    local h = opt.h or 12
    local k = opt.windK or 1
    e:set{count = max(0, round(n)), x = CX - w // 2, w = w, y = BASE_Y + (opt.dy or 0) - h, h = h,
      vx = {-25 + round(wind * k), 25 + round(wind * k)}, vy = {round(vy1 * up), round(vy2 * up)}}
  end
  layer(em.core, 30 * clamp((f - 0.35) / 0.65, 0, 1), 100, -260, -150)
  layer(em.mid, 35 * clamp((f - 0.12) / 0.88, 0, 1), 150, -230, -130)
  layer(em.outer, 35 * clamp(f / 0.4, 0, 1), 190, -200, -110)
  local smoke = 6 + 14 * (1 - f) + (now < S.smotherUntil and 10 or 0)
  if S.heat < 0.8 then smoke = 4 end
  layer(em.smoke, smoke, 90, -110, -70, {h = 40, dy = -round(170 * up), windK = 1.6})
  layer(em.embers, 18 * f * f, 150, -480, -240)
end

local function sparks(n, x, y)
  shoot(em.sparks, n, x, y, {-260 + round(S.wind), 260 + round(S.wind)}, {-650, -250})
end

local function throwLog(now)
  if S.state ~= "play" then return end
  if not nearFire() then return say("Get closer to the fire.", now) end
  if S.logs == 0 then return say("No logs: fetch some in the woods.", now) end
  S.logs = S.logs - 1
  S.fuel = S.fuel + LOG_FUEL
  if S.heat < 20 and now - S.kindled > 5000 then
    S.heat = S.heat * 0.6
    S.smotherUntil = now + 6000
    say("The log smothers the weak embers. Twigs first (T)!", now)
    beep(90, 80)
  else
    sparks(12, CX, BASE_Y)
    beep(140, 40)
  end
end

local function throwTwigs(now)
  if S.state ~= "play" then return end
  if not nearFire() then return say("Get closer to the fire.", now) end
  if S.twigs == 0 then return say("No twigs: fetch some in the woods.", now) end
  S.twigs = S.twigs - 1
  S.fuel = S.fuel + TWIG_FUEL
  S.heat = min(100, S.heat + 12)
  S.kindled = now
  S.smotherUntil = 0
  sparks(5, CX, BASE_Y)
  beep(600, 20)
end

-- --------------------------------------------------------------- world

local function updateFire(dt, now)
  local burn = (0.5 + S.heat / 70) * (1 + abs(S.wind) / 150)
  if S.fuel > 0 then S.fuel = max(0, S.fuel - burn * dt) end
  local target = S.fuel > 0 and min(100, 12 + S.fuel * 2) or 0
  if now < S.smotherUntil then target = min(target, S.heat) end
  local k = target > S.heat and 0.45 or 0.22
  S.heat = S.heat + (target - S.heat) * min(1, k * dt)
  if raining() then S.heat = S.heat - 2.2 * dt end
  S.heat = clamp(S.heat, 0, 100)
  if S.heat < 0.8 then finish("lost", "The fire went out.") end
end

local function updateWeather(dt, now)
  if now >= S.windAt then
    local strength = 20 + min(60, floor(S.minutes / 6))
    S.windTarget = random(-strength, strength)
    S.windAt = now + random(4000, 10000)
  end
  S.wind = S.wind + (S.windTarget - S.wind) * min(1, dt * 0.8)
  if S.minutes >= S.nextRain and not raining() then
    S.rainUntil = S.minutes + random(36, 70)
    S.nextRain = S.rainUntil + random(80, 160)
    em.rain:set{count = 60}
    say("Rain! It cools the fire down.", now)
  end
  if S.rainUntil > 0 and not raining() then
    S.rainUntil = 0
    em.rain:set{count = 0}
  end
  if raining() then
    local w = round(S.wind * 3)
    em.rain:set{vx = {w - 20, w + 20}, vy = {520, 700}}
  end
  if S.minutes > 540 then em.stars:set{color = 244, color2 = 237} end
end

-- Sparks of a big fire light the grass; grass fires spread outward.
local function updateGrass(dt, now)
  if S.heat > 80 and not raining() then
    local chance = 0.12 * (S.heat - 80) / 20 * (1 + abs(S.wind) / 60)
    if random() < chance * dt then
      local dir = random() < 0.5 and -1 or 1
      if abs(S.wind) > 10 and random() < 0.75 then dir = S.wind > 0 and 1 or -1 end
      local col = FX + dir * random(6, 18)
      if not S.fires[col] then
        S.fires[col] = {t = now, stomp = 0}
        shoot(em.sparks, 6, (col + 0.5) * CW, BASE_Y, {-40, 40}, {-200, -80})
        say("A spark caught the grass! Stomp it out.", now)
        beep(880, 30)
      end
    end
  end
  local new = {}
  for col, f in pairs(S.fires) do
    if raining() then f.t = f.t + dt * 1000 * 0.5 end  -- the rain slows it
    if now - f.t > 4000 then
      local out = col + (col < FX and -1 or 1)
      if not S.fires[out] then new[out] = {t = now, stomp = 0} end
      f.t = now
    end
  end
  for col, f in pairs(new) do S.fires[col] = f end
  for col in pairs(S.fires) do
    if col < WOODS or col >= COLS - WOODS then
      return finish("lost", "The grass fire reached the woods.")
    end
  end
  local here = S.fires[round(S.px)]
  if here then
    here.stomp = here.stomp + dt
    if here.stomp >= 0.35 then
      S.fires[round(S.px)] = nil
      S.stomped = S.stomped + 1
      S.score = S.score + 10
      beep(200, 30)
    end
  end
  -- A few embers over each grass fire.
  if now % 300 < 20 then
    for col in pairs(S.fires) do
      shoot(em.sparks, 1, (col + 0.5) * CW, BASE_Y, {-30, 30}, {-160, -60})
    end
  end
end

-- Wolves wait at the edge of the light. They follow whoever walks out of
-- it on their side, and run from a blazing fire.
local function updateWolves(dt, now)
  local most = S.minutes < 60 and 0 or min(4, 1 + (S.minutes - 60) // 150)
  if #S.wolves < most and S.minutes >= S.nextWolf then
    local side = random() < 0.5 and -1 or 1
    local x = side < 0 and 0 or COLS - 2
    if abs(S.px - x) > 12 then
      S.wolves[#S.wolves + 1] = {x = x, side = side, flee = 0, seed = random(0, 2999)}
      S.nextWolf = S.minutes + random(30, 60)
      say("Eyes in the dark...", now)
    end
  end
  local R = lightRadius()
  local scared = S.heat > 75
  local outside = abs(S.px - FX) > R
  for _, w in ipairs(S.wolves) do
    local target, speed
    if scared or now < w.flee then
      target, speed = w.side < 0 and 0 or COLS - 2, 7
    elseif outside and (S.px - FX) * w.side > 0 then
      target, speed = S.px, 6 + 4 * (1 - S.heat / 100)
    else
      target, speed = FX + w.side * (R + 3), 4
    end
    target = clamp(target, 0, COLS - 2)
    local step = speed * dt
    if abs(target - w.x) <= step then w.x = target
    else w.x = w.x + (target > w.x and step or -step) end
    -- Never in the light.
    if abs(w.x - FX) < R then w.x = clamp(FX + w.side * R, 0, COLS - 2) end
    if outside and not scared and now >= w.flee and abs(w.x - S.px) < 1.2 then
      S.lives = S.lives - 1
      S.logs, S.twigs = 0, 0
      w.flee = now + 8000
      beep(110, 200)
      if S.lives == 0 then return finish("lost", "The wolves got you.") end
      say("A wolf bit you! You dropped your wood.", now)
    end
  end
end

local function update(dt, now)
  S.minutes = (now - S.t0) / 1000 / NIGHT_S * 600
  if S.minutes >= 600 then
    S.score = S.score + round(S.heat)
    return finish("won", "Dawn! The fire made it through the night.")
  end
  if inWoods() then
    S.gather = S.gather + dt
    if S.twigs < MAX_TWIGS and S.gather >= 0.6 then
      S.twigs, S.gather = S.twigs + 1, 0
    elseif S.twigs >= MAX_TWIGS and S.logs < MAX_LOGS and S.gather >= 1.4 then
      S.logs, S.gather = S.logs + 1, 0
    end
  else
    S.gather = 0
  end
  updateFire(dt, now)
  updateWeather(dt, now)
  updateGrass(dt, now)
  updateWolves(dt, now)
  if S.heat >= 50 then S.score = S.score + dt * 2 end  -- a cozy fire
end

-- ---------------------------------------------------------------- draw

local function line(y, text, attr)
  local n = utf8.len(text) or #text
  if n < COLS then text = text .. string.rep(" ", COLS - n) end
  term.put(0, y, text, attr)
end

local function bar(v, n)
  local k = clamp(round(v * n), 0, n)
  return string.rep("█", k) .. string.rep("·", n - k)
end

local function drawHud(now)
  local m = floor(S.minutes)
  local h = (20 + m // 60) % 24
  line(1, string.format(" FIRE KEEPER   %02d:%02d   %s", h, m % 60,
    raining() and "rain" or (abs(S.wind) > 35 and "windy" or "")), 15)
  line(2, string.format(" heat %s   fuel %s", bar(S.heat / 100, 20), bar(min(S.fuel, 60) / 60, 12)),
    S.heat < 20 and 12 or 14)
  line(3, string.format(" logs %d/%d   twigs %d/%d   lives %s   score %d", S.logs, MAX_LOGS, S.twigs,
    MAX_TWIGS, string.rep("♥", S.lives), floor(S.score)), 7)
  line(4, now < S.msgUntil and (" " .. S.msg) or "", 11)
  line(ROWS - 1, " ←/→ walk  space: log  t: twigs  (stand in the woods to gather)  q: quit", 8)
end

local function drawScene(now)
  local R = lightRadius()
  -- The woods, grass and ground.
  for c = 0, COLS - 1 do
    local d = abs(c - FX)
    if c < WOODS or c >= COLS - WOODS then
      term.cell(c, GY - 1, (c % 2 == 0) and 186 or 32, 6)
    else
      local ch = (c * 7 % 5 == 0) and 34 or (c % 3 == 0 and 44 or 32)
      term.cell(c, GY - 1, d <= R and ch or 32, 2)
    end
    term.cell(c, GY, 223, d <= R and 6 or (d <= R + 6 and 8 or 0))
  end
  -- The logs on the fire, glowing with its heat.
  local n = clamp((S.fuel + 9) // 10, 0, 7)
  for i = 0, n - 1 do
    local c = FX - n // 2 + i
    term.cell(c, GY - 1, 220, (S.heat > 30 and (i + now // 300) % 3 == 0) and 12 or 6)
  end
  -- Grass fires.
  for col in pairs(S.fires) do
    term.cell(col, GY - 1, 30, ((col + now // 150) % 2 == 0) and 12 or 14)
  end
  -- Wolves: eyes that blink.
  for _, w in ipairs(S.wolves) do
    if (now + w.seed) % 3000 > 150 then
      local x = round(w.x)
      term.cell(x, GY - 1, 249, now < w.flee and 6 or 14)
      term.cell(x + 1, GY - 1, 249, now < w.flee and 6 or 14)
    end
  end
  term.cell(round(S.px), GY - 1, 2, 15)
end

-- Pines on both sides, drawn once.
local function drawWoods()
  for c = 0, COLS - 1 do
    if c < WOODS or c >= COLS - WOODS then
      local h = 7 + (c * 37) % 9
      for r = 1, h do
        local ch = r == h and 30 or (r % 2 == 0 and 30 or 5)
        term.cell(c, GY - 1 - r, ch, (r + c) % 4 == 0 and 10 or 2)
      end
    end
  end
end

local function drawEnd()
  local lines = {S.ending, string.format("Score %d, %d grass fires stomped", floor(S.score), S.stomped),
    "r: play again   q: quit"}
  local y = GY - 16
  for i, t in ipairs(lines) do
    local n = utf8.len(t)
    term.put((COLS - n) // 2, y + i * 2, t, i == 1 and 15 or 7)
  end
end

-- ---------------------------------------------------------------- main

term.cls()
term.showcursor(false)
sys.saver(false)

local ok, err = pcall(function()
  makeEmitters()
  local now = sys.millis()
  reset(now)
  drawWoods()
  local last, lookAt, drawAt = now, 0, 0
  local pressed = {}  -- when each arrow went down
  while true do
    now = sys.millis()
    local e = key.poll()
    while e do
      if e.type == "key" then
        if e.key == "esc" then return end
        if e.key == "left" or e.key == "right" then
          -- One step per press; held down, the walk goes on by itself.
          local walking = pressed[e.key] and now - pressed[e.key] > 180 and key.held(e.key)
          if S.state == "play" and not walking then
            S.px = clamp(S.px + (e.key == "left" and -1 or 1), 0, COLS - 1)
          end
          if not walking then pressed[e.key] = pressed[e.key] or now end
        elseif e.key == "space" then throwLog(now) end
      elseif e.type == "char" then
        local ch = e.ch:lower()
        if ch == "q" then return
        elseif ch == " " then throwLog(now)
        elseif ch == "t" then throwTwigs(now)
        elseif ch == "r" and S.state ~= "play" then
          term.cls()
          reset(now)
          drawWoods()
        end
      end
      e = key.poll()
    end
    local dt = min(0.1, (now - last) / 1000)
    last = now
    if S.state == "play" then
      for dir, sign in pairs{left = -1, right = 1} do
        if not key.held(dir) then pressed[dir] = nil
        elseif pressed[dir] and now - pressed[dir] > 180 then S.px = S.px + sign * SPEED * dt end
      end
      S.px = clamp(S.px, 0, COLS - 1)
      update(dt, now)
    else
      updateFire(dt, now)  -- what is left burns down
    end
    if now >= lookAt then
      fireLook(now)
      lookAt = now + 150
    end
    if now >= drawAt then
      drawScene(now)
      drawHud(now)
      if S.state ~= "play" then drawEnd() end
      drawAt = now + 50
    end
    sys.sleep(15)
  end
end)

for _, e in pairs(em) do e:remove() end
term.cls()
term.showcursor(true)
if not ok then print("firekeeper: " .. tostring(err)) end
