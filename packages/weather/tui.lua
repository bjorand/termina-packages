-- weather.tui: the terminal version of weather, for the A> prompt. Same data
-- as the desktop window, drawn with CP437 blocks: a picture of the sky, the
-- temperature in big digits, 24 hourly bars and 6 days.
-- Keys: C change city, R refresh, U °C/°F, Q or Esc quit.
local wd = require "weather.data"
local round, deg = wd.round, wd.deg

local REFRESH_MS = 15 * 60 * 1000
local COLS, ROWS = term.cols(), term.rows()
local BG = 0

-- 11x5 pictures: the art, then one color letter per character (space: none).
local INK = {Y = 14, W = 15, G = 7, D = 8, C = 11, B = 9}
local ART = {
  clear = {
    {"  \\  |  /  ", "  Y  Y  Y  "},
    {"   ▄███▄   ", "   YYYYY   "},
    {" ──█████── ", " YYYYYYYYY "},
    {"   ▀███▀   ", "   YYYYY   "},
    {"  /  |  \\  ", "  Y  Y  Y  "},
  },
  moon = {
    {"   ▄▄██▀   ", "   WWWWW   "},
    {"  ███▀     ", "  WWWW     "},
    {"  ███      ", "  WWW      "},
    {"  ███▄     ", "  WWWW     "},
    {"   ▀▀██▄   ", "   WWWWW   "},
  },
  few = {
    {"  \\  |  /  ", "  Y  Y  Y  "},
    {"   ▄███▄   ", "   YYYYY   "},
    {" ──████▄▄  ", " YYYYYYWW  "},
    {"   ▀▄█████▄", "   YWWWWWWW"},
    {"    ▀▀▀▀▀▀ ", "    WWWWWW "},
  },
  partly = {
    {" \\ | /     ", " Y Y Y     "},
    {"─ ▄█▄ ▄▄▄  ", "Y YYY WWW  "},
    {"  ▀▄██████▄", "  YWWWWWWWW"},
    {"  █████████", "  WWWWWWWWW"},
    {"   ▀▀▀▀▀▀▀ ", "   WWWWWWW "},
  },
  overcast = {
    {"       ▄▄  ", "       GG  "},
    {"    ▄▄▄███▄", "    WWWGGGG"},
    {" ▄▄█████▄█▀", " WWWWWWWWGG"},
    {"███████████", "WWWWWWWWWWW"},
    {" ▀▀▀▀▀▀▀▀▀ ", " WWWWWWWWW "},
  },
  fog = {
    {"    ▄▄▄    ", "    GGG    "},
    {" ▄▄█████▄▄ ", " GGGGGGGGG "},
    {" ▀▀▀▀▀▀▀▀▀ ", " GGGGGGGGG "},
    {" ───────── ", " GGGGGGGGG "},
    {"  ───────  ", "  GGGGGGG  "},
  },
  drizzle = {
    {"    ▄▄▄    ", "    GGG    "},
    {" ▄▄█████▄▄ ", " GGGGGGGGG "},
    {" ▀▀▀▀▀▀▀▀▀ ", " GGGGGGGGG "},
    {"  ' ' ' '  ", "  C C C C  "},
    {"   ' ' '   ", "   C C C   "},
  },
  rain = {
    {"    ▄▄▄    ", "    GGG    "},
    {" ▄▄█████▄▄ ", " GGGGGGGGG "},
    {" ▀▀▀▀▀▀▀▀▀ ", " GGGGGGGGG "},
    {"  / / / /  ", "  C C C C  "},
    {" / / / /   ", " C C C C   "},
  },
  snow = {
    {"    ▄▄▄    ", "    WWW    "},
    {" ▄▄█████▄▄ ", " WWWWWWWWW "},
    {" ▀▀▀▀▀▀▀▀▀ ", " WWWWWWWWW "},
    {"  * * * *  ", "  W W W W  "},
    {" * * * *   ", " W W W W   "},
  },
  storm = {
    {"    ▄▄▄    ", "    DDD    "},
    {" ▄▄█████▄▄ ", " DDDDDDDDD "},
    {" ▀▀▀▀█▀▀▀▀ ", " DDDDYDDDD "},
    {"  / ▄▀ /   ", "  C YY C   "},
    {" / ▀▀ /    ", " C YY C    "},
  },
}

local function art(x, y, code, night, bg)
  local k = wd.kind(code)
  if night and k == "clear" then k = "moon" end
  for row, line in ipairs(ART[k]) do
    local i, mask = 0, line[2]
    for _, cp in utf8.codes(line[1]) do
      i = i + 1
      local ink = INK[mask:sub(i, i)]
      if ink then term.cell(x + i - 1, y + row - 1, utf8.char(cp), bg * 16 + ink) end
    end
  end
end

-- Big digits: the 5x7 dot font, two dot rows per text row with half blocks.
local function bigtext(x, y, s, attr)
  for ch in s:gmatch(".") do
    local g = wd.BIG[ch]
    if g then
      for row = 0, 3 do
        local top, bottom = g[row * 2 + 1], g[row * 2 + 2] or 0
        for col = 0, 4 do
          local bit = 16 >> col
          local t, b = top & bit ~= 0, bottom & bit ~= 0
          local c = t and b and "█" or t and "▀" or b and "▄" or nil
          if c then term.cell(x + col, y + row, c, attr) end
        end
      end
    end
    x = x + 6
  end
  return x
end

-- ---------------------------------------------------------------- screen

local place, fahrenheit = wd.load()
local wx, status, updated = nil, nil, ""
-- 60x20 mode: no pictures under the days, so that everything fits.
local compact = ROWS < 26 or (COLS - 2) // 6 < 12

local function put(x, y, s, attr) return term.put(x, y, s, attr or BG * 16 + 15) end

local function band(y, attr) term.fill(y, " ", attr) end

local function rule(y, title)
  term.fill(y, "─", BG * 16 + 8)
  put(2, y, " " .. title .. " ", BG * 16 + 7)
end

local function tempColor(t)
  local c = fahrenheit and (t - 32) * 5 / 9 or t
  if c >= 25 then return 12 elseif c >= 15 then return 14 elseif c >= 5 then return 10 end
  return 11
end

local function hero(y0)
  local sky = 1
  if wx then
    if wx.night or wd.kind(wx.code) == "storm" then sky = 0
    elseif wd.dull(wx.code) then sky = 8 end
  end
  for y = y0, y0 + 6 do band(y, sky * 16 + 15) end
  local a = sky * 16 + 15
  if not wx then
    put(3, y0 + 3, status or "Loading...", a)
    return
  end
  art(3, y0 + 1, wx.code, wx.night, sky)
  local x = bigtext(17, y0 + 1, tostring(round(wx.temp)), a)
  put(x, y0 + 1, "°" .. (fahrenheit and "F" or "C"), a)
  put(17, y0 + 5, wd.words(wx.code), sky * 16 + 14)

  local rx, vx = COLS - 27, COLS - 16
  local label = sky * 16 + 7
  local rows = {
    {"Feels", deg(wx.feels)},
    {"Humidity", round(wx.humidity) .. "%"},
    {"Wind", round(wx.wind) .. (fahrenheit and " mph" or " km/h")},
  }
  local today = wx.days[1]
  if today then
    rows[4] = {"Sun", today.rise:sub(12, 16) .. " - " .. today.set:sub(12, 16)}
    rows[5] = {"High/low", deg(today.hi) .. " / " .. deg(today.lo)}
  end
  for i, r in ipairs(rows) do
    put(rx, y0 + i, r[1], label)
    put(vx, y0 + i, r[2], a)
  end
end

-- 24 bars in half-row steps, colored by temperature, labels every 3 hours.
local function hourly(y0, h)
  rule(y0, "Next 24 hours")
  local hs = wx.hours
  local n = #hs
  if n == 0 then return end
  local lo, hi = math.huge, -math.huge
  for _, x in ipairs(hs) do
    lo, hi = math.min(lo, x.temp), math.max(hi, x.temp)
  end
  lo = lo - math.max(1, (hi - lo) * 0.25)  -- the coldest hour keeps a stub
  if hi - lo < 4 then hi = lo + 4 end
  local bw = math.min(3, (COLS - 4) // n)
  local left = (COLS - bw * n) // 2
  local top, bottom = y0 + 2, y0 + 1 + h  -- bar rows
  local steps = h * 2
  local levels = {}
  for i, x in ipairs(hs) do
    local level = math.max(1, round((x.temp - lo) * steps / (hi - lo)))
    levels[i] = level
    local cx = left + (i - 1) * bw
    local attr = BG * 16 + tempColor(x.temp)
    for row = 0, h - 1 do
      local filled = level - (h - 1 - row) * 2  -- half rows filled in this text row
      local c = filled >= 2 and "█" or filled == 1 and "▄" or " "
      for k = 0, bw - 2 do term.cell(cx + k, top + row, c, attr) end
      if bw == 1 then term.cell(cx, top + row, c, attr) end
    end
  end
  -- Labels last, so that the next bars do not cover them.
  for i = 1, n, 3 do
    local cx = left + (i - 1) * bw
    put(cx, top + h - 2 - (levels[i] - 1) // 2, deg(hs[i].temp), BG * 16 + 15)
    put(cx, bottom + 1, i == 1 and "Now" or string.format("%02dh", hs[i].hour), BG * 16 + (i == 1 and 15 or 7))
  end
end

local function daily(y0)
  rule(y0, "Next 6 days")
  local ds = wx.days
  local n = #ds
  if n == 0 then return end
  local lo, hi = math.huge, -math.huge
  for _, d in ipairs(ds) do
    lo, hi = math.min(lo, d.lo), math.max(hi, d.hi)
  end
  if hi - lo < 1 then hi = lo + 1 end
  local cw = (COLS - 2) // n
  for i, d in ipairs(ds) do
    local x0 = 1 + (i - 1) * cw
    local y = y0 + 1
    local name = wd.dayname(d, i)
    put(x0 + (cw - #name) // 2, y, name, BG * 16 + (i == 1 and 15 or 7))
    y = y + 1
    if not compact then
      art(x0 + (cw - 11) // 2, y, d.code, false, BG)
      y = y + 5
    end
    local a, b = deg(d.hi), deg(d.lo)
    local tx = x0 + (cw - (utf8.len(a) + 1 + utf8.len(b))) // 2
    tx = tx + put(tx, y, a, BG * 16 + 15) + 1
    put(tx, y, b, BG * 16 + 7)
    -- Where the day sits between the coldest and warmest of the week.
    local bw = cw - 3
    local s = round((d.lo - lo) * (bw - 1) / (hi - lo))
    local e = round((d.hi - lo) * (bw - 1) / (hi - lo))
    for k = 0, bw - 1 do
      local on = k >= s and k <= e
      term.cell(x0 + 1 + k, y + 1, on and "█" or "░", BG * 16 + (on and tempColor(d.hi) or 8))
    end
  end
end

local function header()
  local a = 1 * 16 + 15
  band(1, a)
  term.cell(1, 1, 15, 1 * 16 + 14)  -- CP437 15: a sun
  put(3, 1, "WEATHER", 1 * 16 + 14)
  put(12, 1, place and place.name or "No city", a)
  if wx then
    local date = wd.longdate(wx.time)
    put(COLS - 1 - utf8.len(date), 1, date, a)
  end
end

local function footer(msg)
  local y = ROWS - 1
  band(y, 1 * 16 + 15)
  if msg then
    put(1, y, msg, 1 * 16 + 15)
    return
  end
  local keys = "C city  R refresh  U °" .. (fahrenheit and "C" or "F") .. "  Q quit"
  put(1, y, keys, 1 * 16 + 15)
  local src = wx and ("Updated " .. updated .. " · Open-Meteo") or "Open-Meteo"
  put(COLS - 1 - utf8.len(src), y, src, 1 * 16 + 7)
end

local function draw()
  term.attr(BG * 16 + 15)
  term.cls()
  header()
  hero(2)
  if wx then
    if compact then
      hourly(9, 2)
      daily(14)
    else
      hourly(9, 3)
      daily(16)
    end
  end
  footer()
end

-- One-line editor on the bottom row; nil if Esc.
local function ask(prompt)
  local s = ""
  while true do
    footer(prompt .. s .. "_")
    local e = key.wait()
    if e.type == "char" then
      if utf8.len(s) < 30 then s = s .. e.ch end
    elseif e.type == "key" then
      if e.key == "enter" then return s
      elseif e.key == "esc" then return nil
      elseif e.key == "backspace" and #s > 0 then
        s = s:sub(1, utf8.offset(s, -1) - 1)
      end
    end
  end
end

local function refresh()
  if not place then return end
  status = "Loading..."
  if not wx then draw() else footer("Loading...") end
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
  local name = ask("City: ")
  if not name or name:match("^%s*$") then footer() return false end
  footer("Looking for " .. name .. "...")
  local p, err = wd.geocode(name)
  if not p then
    footer(err .. " (any key)")
    key.wait()
    footer()
    return false
  end
  place, wx = p, nil
  wd.savePlace(p)
  return true
end

-- ---------------------------------------------------------------------- main

local saved = term.attr()
term.showcursor(false)
if arg[1] then  -- weather <city>: look it up and keep it
  local p = wd.geocode(table.concat(arg, " "))
  if p then
    place = p
    wd.savePlace(p)
  end
end
draw()
if not place and not chooseCity() then place = wd.DEFAULT end
refresh()

local last = sys.millis()
while true do
  local e = key.poll()
  if e then
    local k = e.type == "char" and e.ch:lower() or e.type == "key" and e.key or nil
    if k == "q" or k == "esc" then break
    elseif k == "c" then
      if chooseCity() then refresh() last = sys.millis() end
    elseif k == "r" then
      refresh()
      last = sys.millis()
    elseif k == "u" then
      fahrenheit = not fahrenheit
      wd.saveUnit(fahrenheit)
      refresh()
      last = sys.millis()
    end
  elseif sys.millis() - last >= REFRESH_MS then
    refresh()
    last = sys.millis()
  else
    sys.sleep(50)
  end
end

term.attr(saved)
term.cls()
term.showcursor(true)
