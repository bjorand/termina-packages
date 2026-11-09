-- trader.save: the game in progress and the high scores, kept in /.trader
-- as Lua tables ("return {...}") read back without access to anything.
local fs = termina.fs
local M = {}

M.TOP = 10
local DIR = "/.trader"
local GAME, SCORES = DIR .. "/save.lua", DIR .. "/scores.lua"
local VERSION = 1

local function ser(v, out)
  local t = type(v)
  if t == "number" then
    out[#out + 1] = math.type(v) == "integer" and string.format("%d", v) or string.format("%.9g", v)
  elseif t == "string" then
    out[#out + 1] = string.format("%q", v)
  elseif t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "table" then
    out[#out + 1] = "{"
    local n = #v
    for i = 1, n do
      ser(v[i], out)
      out[#out + 1] = ","
    end
    for k, x in pairs(v) do
      if not (math.type(k) == "integer" and k >= 1 and k <= n) then
        out[#out + 1] = "["
        ser(k, out)
        out[#out + 1] = "]="
        ser(x, out)
        out[#out + 1] = ","
      end
    end
    out[#out + 1] = "}\n"
  end
end

local function write(path, v)
  if not fs.isdir(DIR) then fs.mkdir(DIR) end
  local out = {"return "}
  ser(v, out)
  return fs.write(path, table.concat(out))
end

local function read(path)
  if not fs.exists(path) then return nil end
  local f = load(fs.read(path) or "", "=" .. path, "t", {})
  if not f then return nil end
  local ok, v = pcall(f)
  if ok and type(v) == "table" then return v end
end

-- The saved game: {m = market, b = book, ...} or nil.
function M.game()
  local g = read(GAME)
  if g and g.v == VERSION and type(g.m) == "table" and type(g.b) == "table" then return g end
end

function M.store(g)
  g.v = VERSION
  return write(GAME, g)
end

function M.drop()
  if fs.exists(GAME) then fs.remove(GAME) end
end

-- Best first: {{n = initials, s = net worth in cents}...}
function M.scores()
  local s = read(SCORES) or {}
  for k = #s, 1, -1 do
    if type(s[k]) ~= "table" or type(s[k].s) ~= "number" then table.remove(s, k) end
  end
  return s
end

function M.qualifies(score)
  local s = M.scores()
  return score > 0 and (#s < M.TOP or score > s[#s].s)
end

-- → rank of the new score
function M.add(name, score)
  local s = M.scores()
  local rank = #s + 1
  for k, e in ipairs(s) do
    if score > e.s then rank = k break end
  end
  table.insert(s, rank, {n = name, s = score})
  while #s > M.TOP do table.remove(s) end
  write(SCORES, s)
  return rank
end

return M
