-- nightstand.sky: what moves and what shines. Weather pictures, the sun's
-- course, the moon's phase, and the weather falling on the screen: rain,
-- snow, haze, sparkles or stars. Particles only land on black dots, so they
-- pass behind the clock and the text, and only their own dots are erased.
local M = {}

local floor, sin, cos, pi, random = math.floor, math.sin, math.cos, math.pi, math.random
local function I(v) return floor(v + 0.5) end

-- ------------------------------------------------------------- pictures

local function disc(s, x, y, r, c) s:circle(I(x), I(y), I(r), c, true) end
local function line(s, x0, y0, x1, y1, c) s:line(I(x0), I(y0), I(x1), I(y1), c) end

local function sun(s, cx, cy, k, P)
  disc(s, cx, cy, 7 * k, P(14))
  for i = 0, 7 do
    local a = i * pi / 4
    line(s, cx + cos(a) * 10 * k, cy + sin(a) * 10 * k, cx + cos(a) * 13 * k, cy + sin(a) * 13 * k, P(14))
  end
end

local function moon(s, cx, cy, k, P)
  disc(s, cx, cy, 8 * k, P(15))
  disc(s, cx + 4 * k, cy - 3 * k, 7 * k, 0)
end

local function cloud(s, cx, cy, k, c)
  disc(s, cx - 6 * k, cy + 2 * k, 5 * k, c)
  disc(s, cx + 1 * k, cy - 2 * k, 7 * k, c)
  disc(s, cx + 8 * k, cy + 2 * k, 5 * k, c)
  s:box(I(cx - 6 * k), I(cy + 2 * k), I(14 * k), I(5 * k + 1), c)
end

-- Weather picture centered on cx, cy, about 32 * k dots wide. P maps the
-- colors (night mode).
function M.icon(s, kind, night, cx, cy, k, P)
  if kind == "clear" then
    if night then moon(s, cx, cy, k * 1.4, P) else sun(s, cx, cy, k * 1.2, P) end
  elseif kind == "few" or kind == "partly" then
    if night then moon(s, cx - 5 * k, cy - 4 * k, k, P) else sun(s, cx - 5 * k, cy - 4 * k, k, P) end
    cloud(s, cx + 3 * k, cy + 3 * k, kind == "few" and k * 0.7 or k, P(15))
  elseif kind == "fog" then
    for i, w in ipairs({20, 26, 18}) do
      local y = cy + (i - 2) * 6 * k
      s:box(I(cx - w * k / 2), I(y), I(w * k), I(2 * k), P(7))
    end
  else
    local dark = kind == "storm" or kind == "rain"
    cloud(s, cx, cy - 3 * k, k, P(dark and 8 or 7))
    if kind == "overcast" then
      cloud(s, cx + 4 * k, cy + 1 * k, k * 0.8, P(7))
    elseif kind == "rain" or kind == "drizzle" then
      local n = kind == "rain" and 3 or 2
      for i = 1, n do
        local x = cx + (i - (n + 1) / 2) * 7 * k
        line(s, x, cy + 6 * k, x - 3 * k, cy + (kind == "rain" and 13 or 9) * k, P(11))
      end
    elseif kind == "snow" then
      for i = -1, 1 do disc(s, cx + i * 7 * k, cy + (9 + (i % 2) * 3) * k, 1.5 * k, P(15)) end
    elseif kind == "storm" then
      local pts = {{1, 5}, {-4, 11}, {1, 11}, {-3, 17}}
      for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        for d = 0, 1 do line(s, cx + a[1] * k + d, cy + a[2] * k, cx + b[1] * k + d, cy + b[2] * k, P(14)) end
      end
    end
  end
end

-- ----------------------------------------------------------- sun and moon

local SYNODIC = 29.530588853
local NEW_MOON = 947182440  -- 2000-01-06 18:14 UTC

-- Age of the moon in days (0: new, 14.8: full), from UTC seconds.
function M.moonAge(utc) return ((utc - NEW_MOON) / 86400) % SYNODIC end

local PHASES = {
  {1.85, "New moon"}, {5.54, "Waxing crescent"}, {9.23, "First quarter"},
  {12.92, "Waxing gibbous"}, {16.61, "Full moon"}, {20.30, "Waning gibbous"},
  {23.99, "Last quarter"}, {27.68, "Waning crescent"}, {99, "New moon"},
}

function M.phaseName(age)
  for _, p in ipairs(PHASES) do
    if age < p[1] then return p[2] end
  end
end

-- The moon as it shows tonight: lit part in "lit", the rest in "dark".
function M.moonDisc(s, cx, cy, r, age, lit, dark)
  disc(s, cx, cy, r, dark)
  local p = age / SYNODIC * 2 * pi
  local c = cos(p)
  for dy = -r, r do
    local w = math.sqrt(r * r - dy * dy)
    local x0, x1
    if p < pi then x0, x1 = w * c, w else x0, x1 = -w, -w * c end
    if x1 - x0 >= 0.5 then s:box(I(cx + x0), cy + dy, math.max(1, I(x1 - x0)), 1, lit) end
  end
end

-- Arc from the horizon to the horizon: f in [0, 1] is how far the sun (or
-- the moon) has gone. Returns the position of the marker.
function M.arc(s, cx, cy, R, f, P)
  s:line(cx - R - 10, cy, cx + R + 10, cy, P(8))
  for deg = 0, 180, 6 do
    local a = deg * pi / 180
    local done = (1 - deg / 180) <= f
    s:pixel(I(cx - cos(a) * R), I(cy - sin(a) * R), P(done and 7 or 8))
  end
  local a = f * pi
  return I(cx - cos(a) * R), I(cy - sin(a) * R)
end

M.sun, M.moon = sun, moon

-- ------------------------------------------------------------- particles

local W, H = 640, 480  -- the screen's, from M.size()
local drawn, nd = {}, 0  -- x, y, color of each dot put by the last frame
local parts, kind, t = {}, nil, 0

local function put(s, x, y, c)
  if x < 0 or y < 0 or x >= W or y >= H or s:get(x, y) ~= 0 then return end
  s:pixel(x, y, c)
  drawn[nd + 1], drawn[nd + 2], drawn[nd + 3] = x, y, c
  nd = nd + 3
end

-- Takes the last frame's particles off, leaving what was drawn over them.
function M.erase(s)
  for i = 1, nd, 3 do
    local x, y = drawn[i], drawn[i + 1]
    if s:get(x, y) == drawn[i + 2] then s:pixel(x, y, 0) end
  end
  nd = 0
end

-- After a full redraw (cls): nothing of the last frame is left to erase.
function M.forget() nd = 0 end

-- Where the particles fall: the screen's size.
function M.size(w, h) W, H = w, h end

local SETUP = {
  rain = function() return 46 end, storm = function() return 54 end,
  drizzle = function() return 24 end, snow = function() return 48 end,
  haze = function() return 9 end, sparkle = function() return 14 end,
  stars = function() return 70 end,
}

local function spawn(p, top)
  p.x = random(0, W - 1)
  p.y = top and -random(0, 60) or random(0, H - 1)
  p.v = random(60, 100) / 10
  p.ph = random() * 2 * pi
  p.w = random(16, 60)
end

-- The weather kind (from weather.data) and the time of day choose what falls.
function M.mood(k, night)
  local m
  if k == "rain" or k == "storm" or k == "drizzle" or k == "snow" then m = k
  elseif k == "fog" or k == "overcast" then m = "haze"
  elseif night then m = "stars"
  else m = "sparkle" end
  if m == kind then return end
  kind, parts = m, {}
  for i = 1, SETUP[m]() do
    parts[i] = {}
    spawn(parts[i], false)
  end
end

local function streak(s, p, len, c)
  for k = 0, len - 1 do put(s, I(p.x - k * 0.35), I(p.y - k), c) end
end

-- One step of the animation (about 12 per second).
function M.step(s)
  t = t + 1
  if kind == "rain" or kind == "storm" or kind == "drizzle" then
    local fast = kind ~= "drizzle"
    for _, p in ipairs(parts) do
      p.y = p.y + p.v * (fast and 2.2 or 1)
      p.x = p.x + p.v * (fast and 0.75 or 0.35)
      if p.y - 8 > H or p.x > W + 8 then spawn(p, true) end
      streak(s, p, fast and 8 or 3, fast and 9 or 11)
    end
    if kind == "storm" and t % 90 < 2 then  -- a flash now and then
      local x, y = W // 8 + (t * 37) % (W * 3 // 4), 0
      while y < H * 2 // 5 do
        local nx, ny = x + random(-14, 14), y + random(12, 24)
        local n = math.max(math.abs(nx - x), ny - y)
        for i = 0, n do put(s, I(x + (nx - x) * i / n), I(y + (ny - y) * i / n), 14) end
        x, y = nx, ny
      end
    end
  elseif kind == "snow" then
    for _, p in ipairs(parts) do
      p.y = p.y + p.v * 0.25
      p.x = p.x + sin(p.ph + t * 0.08) * 0.8
      if p.y > H + 2 then spawn(p, true) end
      local x, y = I(p.x), I(p.y)
      put(s, x, y, 15)
      put(s, x + 1, y, 15)
      put(s, x, y + 1, 15)
      put(s, x + 1, y + 1, 7)
    end
  elseif kind == "haze" then
    for _, p in ipairs(parts) do
      p.x = p.x + p.v * 0.06
      if p.x - p.w > W then
        spawn(p, false)
        p.x = -p.w
      end
      local x, y = I(p.x), I(p.y)
      for k = 0, p.w - 1, 2 do put(s, x - k, y, 8) end
    end
  elseif kind == "sparkle" or kind == "stars" then
    local warm = kind == "sparkle"
    for _, p in ipairs(parts) do
      local b = sin(p.ph + t * (warm and 0.09 or 0.05))
      local x, y = floor(p.x), floor(p.y)
      if warm then
        if b > 0.3 then
          put(s, x, y, 14)
          if b > 0.75 then
            put(s, x - 1, y, 6) put(s, x + 1, y, 6) put(s, x, y - 1, 6) put(s, x, y + 1, 6)
          end
        elseif b < -0.95 then
          spawn(p, false)  -- shows up somewhere else
        end
      else
        put(s, x, y, b > 0.6 and 15 or b > -0.2 and 7 or 8)
      end
    end
  end
end

return M
