-- trader.quotes: real stock prices from Yahoo Finance (free, no key), in
-- integer cents. Only ticker symbols are sent. Each call is one HTTPS
-- request that blocks for a second or two.
local net = termina.net
local M = {}

local BASE = "https://query1.finance.yahoo.com/v8/finance/"
local HEADERS = {["User-Agent"] = "termina-trader/2.0"}

-- Enough JSON for Yahoo's answers. null becomes false so that arrays keep
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

local function get(path)
  local parts = {}
  local code, err = net.request{url = BASE .. path, headers = HEADERS,
                                sink = function(chunk) parts[#parts + 1] = chunk end}
  if not code then return nil, err end
  if code == 404 then return nil, "unknown symbol" end
  if code ~= 200 then return nil, "HTTP error " .. code end
  local ok, data = pcall(decode, table.concat(parts))
  if not ok or type(data) ~= "table" then return nil, "unreadable answer" end
  return data
end

local function cents(x) return type(x) == "number" and math.floor(x * 100 + 0.5) or nil end

local function enc(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Prices of several symbols over a range ("1d", "3mo") by interval ("5m",
-- "1d") → {SYM = {t = {times}, c = {cents}, prev = cents}}
function M.spark(syms, range, interval)
  local list = {}
  for i, s in ipairs(syms) do list[i] = enc(s) end
  local d, err = get("spark?symbols=" .. table.concat(list, ",") .. "&range=" .. range .. "&interval=" .. interval)
  if not d then return nil, err end
  local out = {}
  for sym, v in pairs(d) do
    if type(v) == "table" and type(v.close) == "table" and type(v.timestamp) == "table" then
      local t, c = {}, {}
      for k, x in ipairs(v.close) do
        if x then
          t[#t + 1], c[#c + 1] = v.timestamp[k], cents(x)
        end
      end
      out[sym] = {t = t, c = c, prev = cents(v.chartPreviousClose or v.previousClose)}
    end
  end
  return out
end

-- One symbol's latest price, and the hours of its exchange (UTC seconds)
-- → {price, prev, name, currency, open, close, off}
function M.quote(sym)
  local d, err = get("chart/" .. enc(sym) .. "?range=1d&interval=1d")
  if not d then return nil, err end
  local r = d.chart and d.chart.result and d.chart.result[1]
  if not r or not r.meta then return nil, "unknown symbol" end
  local m = r.meta
  local p = m.currentTradingPeriod and m.currentTradingPeriod.regular or {}
  return {price = cents(m.regularMarketPrice), prev = cents(m.chartPreviousClose or m.previousClose),
          name = m.shortName or m.longName or sym, currency = m.currency,
          open = p.start, close = p["end"], off = p.gmtoffset or m.gmtoffset or 0}
end

return M
