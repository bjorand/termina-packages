-- weather.data: what the desktop and terminal versions share. Open-Meteo
-- requests (open-meteo.com, free, no key), a small JSON reader, weather
-- codes, dates, the saved city and the dot font of the big temperature.
local M = {}

function M.round(x) return math.floor(x + 0.5) end

-- ------------------------------------------------------------------ JSON

-- Enough JSON for Open-Meteo answers. null becomes false so that arrays keep
-- their length.
local function decode(s)
  local pos = 1
  local value

  local function skip() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end

  local ESC = {b = "\b", f = "\f", n = "\n", r = "\r", t = "\t"}
  local function str()
    local out, i = {}, pos + 1
    while true do
      local j = s:find('["\\]', i)
      if not j then error("bad JSON string") end
      out[#out + 1] = s:sub(i, j - 1)
      if s:sub(j, j) == '"' then
        pos = j + 1
        return table.concat(out)
      end
      local c = s:sub(j + 1, j + 1)
      if c == "u" then
        out[#out + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16) or 63)
        i = j + 6
      else
        out[#out + 1] = ESC[c] or c
        i = j + 2
      end
    end
  end

  function value()
    skip()
    local c = s:sub(pos, pos)
    if c == "{" then
      local t = {}
      pos = pos + 1
      skip()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
      repeat
        skip()
        local k = str()
        skip()
        pos = pos + 1  -- ':'
        t[k] = value()
        skip()
        c = s:sub(pos, pos)
        pos = pos + 1
      until c ~= ","
      return t
    elseif c == "[" then
      local t = {}
      pos = pos + 1
      skip()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
      repeat
        t[#t + 1] = value()
        skip()
        c = s:sub(pos, pos)
        pos = pos + 1
      until c ~= ","
      return t
    elseif c == '"' then
      return str()
    elseif s:find("^true", pos) then
      pos = pos + 4
      return true
    elseif s:find("^false", pos) or s:find("^null", pos) then
      pos = pos + (c == "f" and 5 or 4)
      return false
    end
    local n = s:match("^-?[%d%.eE+-]+", pos)
    if not n then error("bad JSON at " .. pos) end
    pos = pos + #n
    return tonumber(n)
  end

  return value()
end

-- --------------------------------------------------------------- network

local function urlencode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Plain HTTP: Open-Meteo serves it, and it answers well within the 4 seconds
-- a desktop application may keep control (TLS on the ESP32 can take longer).
local function get(url)
  local parts = {}
  sys.yield()  -- the request blocks: start it with a fresh time budget
  local code, err = net.request{url = url, sink = function(chunk) parts[#parts + 1] = chunk end}
  if not code then return nil, err end
  if code ~= 200 then return nil, "HTTP error " .. code end
  local ok, data = pcall(decode, table.concat(parts))
  if not ok then return nil, "unreadable answer" end
  return data
end

-- City name -> {name = "Lyon, FR", lat, lon}. The name is sent to Open-Meteo.
function M.geocode(name)
  local data, err = get("http://geocoding-api.open-meteo.com/v1/search?count=1&language=en&format=json&name="
                        .. urlencode(name))
  if not data then return nil, err end
  local r = data.results and data.results[1]
  if not r then return nil, "City not found: " .. name end
  local label = r.name
  if r.country_code then label = label .. ", " .. r.country_code end
  return {name = label, lat = string.format("%.4f", r.latitude), lon = string.format("%.4f", r.longitude)}
end

-- Current conditions, 24 hours and 6 days. Keeps only what the screens need,
-- so that the parsed JSON can be freed.
function M.forecast(place, fahrenheit)
  local url = "http://api.open-meteo.com/v1/forecast?latitude=" .. place.lat .. "&longitude=" .. place.lon
    .. "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"
    .. "&hourly=temperature_2m&forecast_hours=24"
    .. "&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"
    .. "&timezone=auto&forecast_days=6"
    .. (fahrenheit and "&temperature_unit=fahrenheit&wind_speed_unit=mph" or "")
  local d, err = get(url)
  if not d then return nil, err end
  if not (d.current and d.hourly and d.daily) then return nil, d.reason or "unexpected answer" end
  local c, hr, dl = d.current, d.hourly, d.daily
  local wx = {
    time = c.time, temp = c.temperature_2m, feels = c.apparent_temperature,
    humidity = c.relative_humidity_2m, wind = c.wind_speed_10m, code = c.weather_code,
    night = c.is_day == 0, hours = {}, days = {},
  }
  for i, t in ipairs(hr.time) do
    wx.hours[i] = {hour = tonumber(t:sub(12, 13)), temp = hr.temperature_2m[i] or 0}
  end
  for i, t in ipairs(dl.time) do
    wx.days[i] = {date = t, code = dl.weather_code[i] or 0,
                  hi = dl.temperature_2m_max[i] or 0, lo = dl.temperature_2m_min[i] or 0,
                  rise = dl.sunrise[i] or "", set = dl.sunset[i] or ""}
  end
  return wx
end

-- ------------------------------------------------------------ saved settings

function M.load()
  local place = {name = store.get("wx.city", ""), lat = store.get("wx.lat", ""), lon = store.get("wx.lon", "")}
  if place.lat == "" then place = nil end
  return place, store.get("wx.unit", "C") == "F"
end

function M.savePlace(p)
  store.set("wx.city", p.name)
  store.set("wx.lat", p.lat)
  store.set("wx.lon", p.lon)
end

function M.saveUnit(fahrenheit) store.set("wx.unit", fahrenheit and "F" or "C") end

M.DEFAULT = {name = "Paris, FR", lat = "48.8534", lon = "2.3488"}

-- ------------------------------------------------------------- weather codes

-- WMO code -> kind of picture.
function M.kind(code)
  if code == 0 then return "clear"
  elseif code == 1 then return "few"
  elseif code == 2 then return "partly"
  elseif code == 3 then return "overcast"
  elseif code == 45 or code == 48 then return "fog"
  elseif code >= 51 and code <= 57 then return "drizzle"
  elseif (code >= 61 and code <= 67) or (code >= 80 and code <= 82) then return "rain"
  elseif (code >= 71 and code <= 77) or code == 85 or code == 86 then return "snow"
  elseif code >= 95 then return "storm"
  end
  return "overcast"
end

local WORDS = {
  [0] = "Clear sky", [1] = "Mainly clear", [2] = "Partly cloudy", [3] = "Overcast",
  [45] = "Fog", [48] = "Freezing fog",
  [51] = "Light drizzle", [53] = "Drizzle", [55] = "Dense drizzle",
  [56] = "Freezing drizzle", [57] = "Freezing drizzle",
  [61] = "Light rain", [63] = "Rain", [65] = "Heavy rain",
  [66] = "Freezing rain", [67] = "Freezing rain",
  [71] = "Light snow", [73] = "Snow", [75] = "Heavy snow", [77] = "Snow grains",
  [80] = "Light showers", [81] = "Showers", [82] = "Violent showers",
  [85] = "Snow showers", [86] = "Heavy snow showers",
  [95] = "Thunderstorm", [96] = "Thunderstorm, hail", [99] = "Thunderstorm, hail",
}

function M.words(code) return WORDS[code] or ("Code " .. code) end

-- Grey skies for these kinds, blue otherwise.
function M.dull(code)
  local k = M.kind(code)
  return k == "overcast" or k == "fog" or k == "rain" or k == "drizzle" or k == "snow"
end

-- --------------------------------------------------------------------- dates

local MONTHS = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
M.DAYS = {[0] = "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}

function M.weekday(date)  -- "2026-10-27" -> 0 (Sunday) .. 6
  local y, m, d = tonumber(date:sub(1, 4)), tonumber(date:sub(6, 7)), tonumber(date:sub(9, 10))
  local t = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4}
  if m < 3 then y = y - 1 end
  return (y + y // 4 - y // 100 + y // 400 + t[m] + d) % 7
end

function M.longdate(time)  -- "2026-10-27T23:45" -> "Tue 27 Oct  23:45"
  return string.format("%s %d %s  %s", M.DAYS[M.weekday(time)], tonumber(time:sub(9, 10)),
                       MONTHS[tonumber(time:sub(6, 7))], time:sub(12, 16))
end

function M.dayname(d, i) return i == 1 and "Today" or M.DAYS[M.weekday(d.date)] end

function M.deg(t) return string.format("%d°", M.round(t)) end

-- ------------------------------------------------------------- big digits

-- 5x7 dots per character, bit 4 = leftmost column.
M.BIG = {
  ["0"] = {14, 17, 17, 17, 17, 17, 14}, ["1"] = {4, 12, 4, 4, 4, 4, 14},
  ["2"] = {14, 17, 1, 2, 4, 8, 31},     ["3"] = {31, 2, 4, 2, 1, 17, 14},
  ["4"] = {2, 6, 10, 18, 31, 2, 2},     ["5"] = {31, 16, 30, 1, 1, 17, 14},
  ["6"] = {6, 8, 16, 30, 17, 17, 14},   ["7"] = {31, 1, 2, 4, 8, 8, 8},
  ["8"] = {14, 17, 17, 14, 17, 17, 14}, ["9"] = {14, 17, 17, 15, 1, 2, 12},
  ["-"] = {0, 0, 0, 31, 0, 0, 0},
}

return M
