-- @app Weather
-- @icon image
-- weather.lua: current conditions, the next 24 hours and 6 days, from
-- Open-Meteo. On the desktop it opens a window; at the A> prompt it runs the
-- terminal version (weather.tui).
-- Keys: C change city, R refresh, U switch between °C and °F.
-- Clicking the city name also changes it.

if not win then
  require "weather.tui"
  return
end

local wd = require "weather.data"
local round, deg = wd.round, wd.deg

local W, H = 312, 232
local HERO_H = 96
local REFRESH_MS = 15 * 60 * 1000

local f = win.open{title = "Weather", w = W, h = H, resizable = false, bg = 0}
if not f then return end

-- ----------------------------------------------------------------- pictures

local function sun(cx, cy, r)
  for i = 0, 7 do
    local a = i * math.pi / 4
    local s, c = math.sin(a), math.cos(a)
    local x0, y0 = round(cx + s * r * 1.3), round(cy - c * r * 1.3)
    local x1, y1 = round(cx + s * r * 1.65), round(cy - c * r * 1.65)
    f:line(x0, y0, x1, y1, 14)
    if r > 12 then f:line(x0 + 1, y0, x1 + 1, y1, 14) end
  end
  f:circle(round(cx), round(cy), round(r), 6, true)
  f:circle(round(cx), round(cy), round(r) - 1, 14, true)
end

-- Crescent drawn dot by dot, so that it sits on any background.
local function moon(cx, cy, r)
  local ox, oy, r2 = cx + r * 0.5, cy - r * 0.35, (r * 0.85) ^ 2
  for y = round(cy - r), round(cy + r) do
    for x = round(cx - r), round(cx + r) do
      local d = (x - cx) ^ 2 + (y - cy) ^ 2
      if d <= r * r and (x - ox) ^ 2 + (y - oy) ^ 2 > r2 then
        f:pixel(x, y, d > (r - 1.5) ^ 2 and 7 or 15)
      end
    end
  end
end

-- Three puffs on a flat base, with a darker rim.
local function cloud(cx, cy, r, fill, rim)
  local puffs = {{-0.45, 0.1, 0.45}, {0.1, -0.2, 0.6}, {0.55, 0.15, 0.4}}
  local x0, x1 = round(cx - r * 0.45), round(cx + r * 0.55)
  local y0, y1 = round(cy + r * 0.1), round(cy + r * 0.55)
  for pass = 1, 2 do
    local c, grow = pass == 1 and rim or fill, pass == 1 and 1 or 0
    for _, p in ipairs(puffs) do
      f:circle(round(cx + p[1] * r), round(cy + p[2] * r), round(p[3] * r) + grow, c, true)
    end
    f:box(x0, y0 - grow, x1 - x0 + 1, y1 - y0 + 1 + 2 * grow, c)
  end
end

local function drops(cx, cy, r, n, c, len)
  for i = 1, n do
    local x = round(cx + (i - (n + 1) / 2) * r * 0.42)
    local y = round(cy + r * 0.62 + (i % 2) * r * 0.12)
    f:line(x, y, round(x - r * 0.12), round(y + r * len), c)
  end
end

local function flakes(cx, cy, r)
  local a = math.max(1, round(r * 0.1))
  for i = 1, 3 do
    local x = round(cx + (i - 2) * r * 0.42)
    local y = round(cy + r * 0.78 + (i % 2) * r * 0.15)
    f:line(x - a, y, x + a, y, 15)
    f:line(x, y - a, x, y + a, 15)
    f:line(x - a, y - a, x + a, y + a, 15)
    f:line(x - a, y + a, x + a, y - a, 15)
  end
end

local function bolt(cx, cy, r)
  local p = {{0.05, 0.35}, {-0.2, 0.75}, {0.05, 0.75}, {-0.15, 1.1}}
  for i = 1, #p - 1 do
    local x0, y0 = round(cx + p[i][1] * r), round(cy + p[i][2] * r)
    local x1, y1 = round(cx + p[i + 1][1] * r), round(cy + p[i + 1][2] * r)
    f:line(x0, y0, x1, y1, 14)
    f:line(x0 + 1, y0, x1 + 1, y1, 14)
  end
end

local function picture(cx, cy, r, code, night)
  local k = wd.kind(code)
  local star = night and moon or sun
  if k == "clear" then
    star(cx, cy, night and r or r * 0.8)
  elseif k == "few" then
    star(cx - r * 0.2, cy - r * 0.2, r * 0.65)
    cloud(cx + r * 0.25, cy + r * 0.3, r * 0.6, 15, 7)
  elseif k == "partly" then
    star(cx - r * 0.3, cy - r * 0.3, r * 0.6)
    cloud(cx + r * 0.05, cy + r * 0.15, r * 0.85, 15, 7)
  elseif k == "overcast" then
    cloud(cx + r * 0.3, cy - r * 0.35, r * 0.65, 7, 8)
    cloud(cx - r * 0.1, cy + r * 0.1, r * 0.9, 15, 7)
  elseif k == "fog" then
    cloud(cx, cy - r * 0.3, r * 0.8, 7, 8)
    for i = 0, 2 do
      local y = round(cy + r * (0.45 + i * 0.22))
      f:line(round(cx - r * (0.8 - i * 0.15)), y, round(cx + r * (0.7 + i * 0.1)), y, 7)
    end
  elseif k == "drizzle" then
    cloud(cx, cy - r * 0.25, r * 0.9, 7, 8)
    drops(cx, cy - r * 0.15, r, 3, 11, 0.15)
  elseif k == "rain" then
    cloud(cx, cy - r * 0.25, r * 0.9, 7, 8)
    drops(cx, cy - r * 0.15, r, 3, 11, 0.4)
  elseif k == "snow" then
    cloud(cx, cy - r * 0.3, r * 0.9, 15, 7)
    flakes(cx, cy - r * 0.15, r)
  else
    cloud(cx, cy - r * 0.3, r * 0.9, 8, 7)
    bolt(cx, cy - r * 0.2, r)
    drops(cx + r * 0.2, cy - r * 0.2, r, 2, 11, 0.3)
  end
end

-- Big digits drawn as separated squares: a LED panel look.
local function bigtext(x, y, s, sc, c, shade)
  for ch in s:gmatch(".") do
    local g = wd.BIG[ch]
    if g then
      for row = 1, 7 do
        for col = 0, 4 do
          if g[row] & (16 >> col) ~= 0 then
            local px, py = x + col * sc, y + (row - 1) * sc
            if shade then f:box(px + 1, py + 1, sc - 1, sc - 1, shade) end
            f:box(px, py, sc - 1, sc - 1, c)
          end
        end
      end
    end
    x = x + 6 * sc
  end
  return x
end

-- -------------------------------------------------------------------- screen

local place, fahrenheit = wd.load()
local wx, status = nil, nil  -- last forecast; message shown instead of it
local updated = ""
local cityBox = {0, 0, 0, 0}

local function text(x, y, s, c, font)  -- with a drop shadow, for the sky
  f:text(x + 1, y + 1, s, 0, nil, font)
  return f:text(x, y, s, c, nil, font)
end

-- Sky in four bands, dithered by lines: dark at the top, light at the horizon.
local function sky(top, bottom, night)
  for y = 0, HERO_H - 1 do
    local p, c = y / HERO_H, top
    if p >= 0.8 then c = bottom
    elseif p >= 0.6 then c = y % 2 == 0 and bottom or top
    elseif p >= 0.4 then c = y % 4 == 0 and bottom or top
    end
    f:line(0, y, W - 1, y, c)
  end
  if night then
    local seed = 17
    for _ = 1, 45 do
      seed = (seed * 75 + 74) % 65537
      local x = seed % W
      seed = (seed * 75 + 74) % 65537
      f:pixel(x, seed % (HERO_H * 6 // 10), seed % 3 == 0 and 15 or 7)
    end
  end
end

local function skyColors()
  if not wx then return 1, 9 end
  if wd.kind(wx.code) == "storm" then return 0, 8 end
  if wx.night then return 0, 1 end
  if wd.dull(wx.code) then return 8, 7 end
  return 1, 9
end

local function hero()
  local top, bottom = skyColors()
  sky(top, bottom, wx and wx.night)
  local cw = text(84, 6, place and place.name or "No city", 15, "vga")
  cityBox = {84, 4, cw + 2, 18}
  if not wx then
    text(84, 34, status or "Loading...", 15, "vga")
    return
  end
  local date = wd.longdate(wx.time)
  text(W - 6 - win.textsize(date), 10, date, 15)

  picture(42, 46, 22, wx.code, wx.night)

  local x = bigtext(84, 26, tostring(round(wx.temp)), 4, 15, 0)
  f:circle(x + 2, 29, 3, 0)
  f:circle(x + 1, 28, 3, 15)
  f:circle(x + 1, 28, 2, 15)
  text(x + 7, 26, fahrenheit and "F" or "C", 15, "vga")
  text(84, 60, wd.words(wx.code), 15, "vga")

  local rx, vx = W - 104, W - 50
  text(rx, 30, "Feels", 7)
  text(vx, 30, deg(wx.feels), 15)
  text(rx, 42, "Humidity", 7)
  text(vx, 42, round(wx.humidity) .. "%", 15)
  text(rx, 54, "Wind", 7)
  text(vx, 54, round(wx.wind) .. (fahrenheit and " mph" or " km/h"), 15)

  local today = wx.days[1]
  if today then
    text(8, HERO_H - 13, "Sunrise " .. today.rise:sub(12, 16) .. "   Sunset " .. today.set:sub(12, 16), 15)
    local hl = "H " .. deg(today.hi) .. "  L " .. deg(today.lo)
    text(W - 8 - win.textsize(hl), HERO_H - 13, hl, 15)
  end
end

-- Temperature curve over the next 24 hours, with the area below it filled.
local function hourly(y0)
  f:text(8, y0, "NEXT 24 HOURS", 8)
  local hs = wx.hours
  local n = #hs
  if n < 2 then return end
  local lo, hi = math.huge, -math.huge
  for _, h in ipairs(hs) do
    lo, hi = math.min(lo, h.temp), math.max(hi, h.temp)
  end
  if hi - lo < 4 then
    local mid = (hi + lo) / 2
    lo, hi = mid - 2, mid + 2
  end
  local left, right = 16, W - 16
  local top, bottom, base = y0 + 22, y0 + 40, y0 + 45
  local function px(i) return left + (i - 1) * (right - left) / (n - 1) end
  local function py(t) return bottom - (t - lo) * (bottom - top) / (hi - lo) end

  for x = left, right do
    local i = (x - left) * (n - 1) / (right - left) + 1
    local a = math.min(math.floor(i), n - 1)
    local t = hs[a].temp + (hs[a + 1].temp - hs[a].temp) * (i - a)
    local y = round(py(t))
    f:line(x, y + 1, x, base, x % 2 == 0 and 1 or 0)
    f:pixel(x, y, 11)
    f:pixel(x, y + 1, 3)
  end
  f:line(left, base + 1, right, base + 1, 8)
  for i = 1, n, 3 do
    local x, y = round(px(i)), round(py(hs[i].temp))
    f:circle(x, y, 2, 14, true)
    local t = deg(hs[i].temp)
    f:text(x - win.textsize(t) // 2, y - 11, t, 15)
    local hh = i == 1 and "Now" or string.format("%02d", hs[i].hour)
    f:text(x - win.textsize(hh) // 2, base + 4, hh, i == 1 and 15 or 7)
  end
end

-- Day columns: name, picture, high and low, and where the day sits in the week.
local function daily(y0)
  local ds = wx.days
  local n = #ds
  if n == 0 then return end
  local lo, hi = math.huge, -math.huge
  for _, d in ipairs(ds) do
    lo, hi = math.min(lo, d.lo), math.max(hi, d.hi)
  end
  if hi - lo < 1 then hi = lo + 1 end
  local cw = (W - 8) // n
  for i, d in ipairs(ds) do
    local x0 = 4 + (i - 1) * cw
    local cx = x0 + cw // 2
    if i > 1 then f:line(x0, y0 + 2, x0, y0 + 52, 8) end
    local name = wd.dayname(d, i)
    f:text(cx - win.textsize(name) // 2, y0 + 2, name, i == 1 and 15 or 7)
    picture(cx, y0 + 24, 11, d.code, false)
    local a, b = deg(d.hi), deg(d.lo)
    local tw = win.textsize(a) + 5 + win.textsize(b)
    local tx = cx - tw // 2
    tx = tx + f:text(tx, y0 + 38, a, 15) + 5
    f:text(tx, y0 + 38, b, 7)
    local bx, bw = x0 + 6, cw - 12
    f:box(bx, y0 + 50, bw, 2, 8)
    local s = round(bx + (d.lo - lo) * bw / (hi - lo))
    local e = round(bx + (d.hi - lo) * bw / (hi - lo))
    f:box(s, y0 + 50, math.max(2, e - s), 2, d.hi >= (fahrenheit and 77 or 25) and 12 or 11)
  end
end

local function draw()
  f:cls(0)
  hero()
  if wx then
    hourly(HERO_H + 4)
    f:line(4, HERO_H + 63, W - 5, HERO_H + 63, 8)
    daily(HERO_H + 67)
  end
  f:line(0, H - 12, W - 1, H - 12, 8)
  f:text(6, H - 9, wx and ("Updated " .. updated) or "Open-Meteo", 8)
  local keys = "C city  R refresh  U °" .. (fahrenheit and "C" or "F")
  f:text(W - 6 - win.textsize(keys), H - 9, keys, 8)
end

local function refresh()
  if not place then return end
  status = "Loading..."
  if not wx then draw() end
  local data, err = wd.forecast(place, fahrenheit)
  if data then
    wx, status = data, nil
    updated = data.time:sub(12, 16)
  else
    wx, status = nil, (err or "error") .. " - R to retry"
  end
  collectgarbage()
  draw()
end

local function chooseCity()
  local name = win.input("Weather", "City:")
  if not name or name:match("^%s*$") then return false end
  status = "Looking for " .. name .. "..."
  draw()
  local p, err = wd.geocode(name)
  if not p then
    status = nil
    draw()
    win.message("Weather", err, "info")
    return false
  end
  place, wx = p, nil
  wd.savePlace(p)
  return true
end

-- ---------------------------------------------------------------------- main

draw()
if not place and not chooseCity() then place = wd.DEFAULT end
refresh()

local last = sys.millis()
win.timer(60 * 1000)
while true do
  local e = win.event()
  local t = e.type
  if t == "close" then break end
  local key = t == "char" and e.ch:lower() or nil
  if key == "c" or (t == "mouse" and e.down and e.button == 0 and e.x >= cityBox[1]
      and e.x < cityBox[1] + cityBox[3] and e.y >= cityBox[2] and e.y < cityBox[2] + cityBox[4]) then
    if chooseCity() then refresh() last = sys.millis() else draw() end
  elseif key == "r" or (t == "timer" and sys.millis() - last >= REFRESH_MS) then
    refresh()
    last = sys.millis()
  elseif key == "u" then
    fahrenheit = not fahrenheit
    wd.saveUnit(fahrenheit)
    refresh()
    last = sys.millis()
  end
end
