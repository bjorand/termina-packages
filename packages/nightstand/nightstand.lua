-- @saver Nightstand
-- nightstand: a bedside clock for the idle screen, in the spirit of a phone's
-- standby mode. The time in big digits, the date, the weather now and over
-- the next 24 hours, the sun's course, the moon's phase, and the weather
-- falling on the screen. From 22:00 to 07:00 everything turns dim red and
-- stops moving. City and units are the Weather app's (weather [city]).
local sys, screen = termina.sys, termina.screen
local wd = require "weather.data"
local font = require "nightstand.font"
local sky = require "nightstand.sky"

local W, H = screen:size()
local REFRESH_MS, RETRY_MS = 15 * 60 * 1000, 60 * 1000
local FRAME_MS, NIGHT_FRAME_MS = 80, 500
local NIGHT_FROM, NIGHT_TO, NIGHT_INK = 22, 7, 4

local place, fahrenheit = wd.load()
place = place or wd.DEFAULT
local wx, wxErr = nil, nil
local fetchAt = sys.millis() + 300  -- the clock shows up first
local dirty = true
local night = false
local lastMin, lastSec = nil, nil
local ox, oy = 0, 0  -- the whole picture moves a little every minute
local colons = {}

local MONTHS = {"January", "February", "March", "April", "May", "June", "July",
                "August", "September", "October", "November", "December"}
local DAYS = {[0] = "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}

local function P(c)
  if night and c ~= 0 then return NIGHT_INK end
  return c
end

local function textw(str, scale, f) return utf8.len(str) * (f == "vga" and 8 or 6) * (scale or 1) end

local function text(x, y, str, c, f, scale)
  return screen:text(x + ox, y + oy, str, P(c), nil, f, scale)
end

local function center(cx, y, str, c, f, scale)
  text(cx - textw(str, scale, f) // 2, y, str, c, f, scale)
end

local function tempColor(t)
  local c = fahrenheit and (t - 32) * 5 / 9 or t
  if c >= 25 then return 12 elseif c >= 15 then return 14 elseif c >= 5 then return 10 end
  return 11
end

local function minutes(iso)  -- "2026-11-02T07:45" -> 465
  return tonumber(iso:sub(12, 13)) * 60 + tonumber(iso:sub(15, 16))
end

-- ---------------------------------------------------------------- layout

local CLOCK_Y = 26
local DOTS_Y = CLOCK_Y + font.H + 16
local DATE_Y = DOTS_Y + 18
local PANEL_Y = 322

local function clockX(str) return (W - font.width(str)) // 2 end

local function dot(sec, c)
  local x0 = (W - 59 * 8) // 2
  screen:circle(x0 + sec * 8 + ox, DOTS_Y + oy, 1, P(c), true)
end

local function drawClock(hh, mm, ss)
  local str = hh and string.format("%02d:%02d", hh, mm) or "--:--"
  colons = font.draw(screen, clockX(str) + ox, CLOCK_Y + oy, str, P(15))
  for sec = 0, 59 do dot(sec, (ss and sec <= ss) and 7 or 8) end
end

local function drawDate(day, month, wday)
  if not day then return end
  center(W // 2, DATE_Y, DAYS[wday] .. " " .. day .. " " .. MONTHS[month], 7, "vga", 2)
end

-- Bottom left: the weather now.
local function drawNow(x0, y0)
  if not wx then
    text(x0, y0 + 30, wxErr and "No weather" or "Weather...", 8, "vga", 2)
    if wxErr then text(x0, y0 + 70, wxErr, 8) end
    text(x0, y0 + 122, place.name, 8)
    return
  end
  sky.icon(screen, wd.kind(wx.code), wx.night, x0 + 34 + ox, y0 + 38 + oy, 2, P)
  local t = wd.deg(wx.temp)
  text(x0 + 82, y0 + 4, t, tempColor(wx.temp), "vga", 4)
  text(x0, y0 + 84, wd.words(wx.code), 15, "vga")
  local today = wx.days[1]
  if today then
    text(x0, y0 + 104, "H " .. wd.deg(today.hi) .. "  L " .. wd.deg(today.lo), 7, "vga")
  end
  text(x0, y0 + 124, place.name, 8)
end

-- Bottom middle: the temperature over the next 24 hours.
local function drawHours(x0, y0, w, h)
  text(x0, y0, "NEXT 24 HOURS", 8)
  if not wx or #wx.hours < 2 then return end
  local hs = wx.hours
  local lo, hi = math.huge, -math.huge
  for _, p in ipairs(hs) do lo, hi = math.min(lo, p.temp), math.max(hi, p.temp) end
  if hi - lo < 4 then hi = lo + 4 end
  local top, bottom = y0 + 26, y0 + 26 + h
  local function px(i) return x0 + (i - 1) * (w - 1) // (#hs - 1) end
  local function py(t) return math.floor(bottom - (t - lo) * h / (hi - lo) + 0.5) end
  local prevx, prevy
  for i, p in ipairs(hs) do
    local x, y = px(i), py(p.temp)
    if i % 2 == 1 then screen:line(x + ox, y + 3 + oy, x + ox, bottom + 4 + oy, P(8)) end
    if prevx then
      screen:line(prevx + ox, prevy + oy, x + ox, y + oy, P(tempColor(p.temp)))
      screen:line(prevx + ox, prevy + 1 + oy, x + ox, y + 1 + oy, P(tempColor(p.temp)))
    end
    prevx, prevy = x, y
  end
  local x1, y1 = px(1), py(hs[1].temp)
  screen:circle(x1 + ox, y1 + oy, 3, P(15), true)
  for i = 1, #hs, 6 do
    local label = i == 1 and "now" or string.format("%02dh", hs[i].hour)
    text(px(i) - (i == 1 and 0 or 9), bottom + 10, label, i == 1 and 15 or 7)
  end
  text(x0 + w - textw(wd.deg(hi)), top - 14, wd.deg(hi), 7)
  text(x0 + w - textw(wd.deg(lo)), bottom - 12, wd.deg(lo), 7)
end

-- Bottom right: the sun's course, or the moon's at night, and its phase.
local function drawSky(cx, y0, hh, mm)
  local R, cy = 78, y0 + 96
  local today = wx and wx.days[1]
  local now = hh and hh * 60 + mm
  local up, f
  if today and now then
    local rise, set = minutes(today.rise), minutes(today.set)
    if now >= rise and now < set then
      up, f = "sun", (now - rise) / (set - rise)
    else
      up = "moon"
      f = ((now - set) % 1440) / ((rise - set) % 1440)
    end
    center(cx, y0 + 108, "\24 " .. today.rise:sub(12, 16) .. "   \25 " .. today.set:sub(12, 16), 7)
  end
  local utc = sys.epoch()
  local age = utc and sky.moonAge(utc)
  -- One ink at night: the moon's dark side becomes an outline.
  local function moon(x, y, r, lit)
    sky.moonDisc(screen, x, y, r, age, P(lit), night and 0 or 8)
    if night then screen:circle(x, y, r, P(8)) end
  end
  if up then
    local x, y = sky.arc(screen, cx + ox, cy + oy, R, f, P)
    if up == "sun" then
      screen:circle(x, y, 7, P(14), true)
    elseif age then
      moon(x, y, 7, 15)
    end
  end
  if age then
    moon(cx + ox, cy - 34 + oy, 16, 7)
    center(cx, y0 + 124, sky.phaseName(age), 8)
  end
end

local function redraw(hh, mm, ss, day, month, wday)
  screen:cls(0)
  sky.forget()
  drawClock(hh, mm, ss)
  drawDate(day, month, wday)
  drawNow(24, PANEL_Y)
  drawHours(236, PANEL_Y, 176, 72)
  drawSky(530, PANEL_Y, hh, mm)
end

local function fetch()
  local data, err = wd.forecast(place, fahrenheit)
  if data then
    wx, wxErr = data, nil
    fetchAt = sys.millis() + REFRESH_MS
  else
    wxErr = err or "error"
    fetchAt = sys.millis() + RETRY_MS
  end
  collectgarbage()
end

return function()
  if sys.millis() >= fetchAt then
    fetch()
    dirty = true
  end
  local hh, mm, ss, day, month, _, wday = sys.time()
  local minute = hh and hh * 60 + mm or -1
  sky.erase(screen)
  if dirty or minute ~= lastMin then
    dirty = false
    lastMin = minute
    night = hh ~= nil and (hh >= NIGHT_FROM or hh < NIGHT_TO)
    if hh then ox, oy = (minute * 7) % 13 - 6, (minute * 5) % 9 - 4 end
    redraw(hh, mm, ss, day, month, wday)
  elseif ss and ss ~= lastSec then
    dot(ss, 7)
    -- The colon beats the seconds.
    for _, x in ipairs(colons) do font.colon(screen, x, CLOCK_Y + oy, ss % 2 == 0 and P(15) or 0) end
  end
  lastSec = ss
  if night then return NIGHT_FRAME_MS end
  sky.mood(wx and wd.kind(wx.code) or "clear", wx and wx.night)
  sky.step(screen)
  return FRAME_MS
end
