-- trader.save: the paper trading account, kept in /.trader/paper.lua as a
-- Lua table ("return {...}") read back without access to anything.
local fs = termina.fs
local M = {}

local DIR = "/.trader"
local FILE = DIR .. "/paper.lua"
local VERSION = 2

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

-- The account: {list, names, b, start, day, log, ...} or nil.
function M.load()
  if not fs.exists(FILE) then return nil end
  local f = load(fs.read(FILE) or "", "=" .. FILE, "t", {})
  if not f then return nil end
  local ok, v = pcall(f)
  if ok and type(v) == "table" and v.v == VERSION and type(v.b) == "table" and type(v.list) == "table" then
    return v
  end
end

function M.store(st)
  st.v = VERSION
  if not fs.isdir(DIR) then fs.mkdir(DIR) end
  local out = {"return "}
  ser(st, out)
  return fs.write(FILE, table.concat(out))
end

return M
