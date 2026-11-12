-- irc.config: /etc/irc.conf, a Lua table: the nick, the servers and the
-- channels to join. Written with the defaults on the first run; /save
-- writes it back with the servers and channels open.
local fs = termina.fs

local M = {PATH = "/etc/irc.conf", data = nil}

local function template(nick)
  return [[
-- Termina IRC settings. Edit, then restart irc (or /save from irc).
return {
  nick = "]] .. nick .. [[",          -- taken? irc adds "_"
  realname = "Termina 80",
  scrollback = 300,          -- lines kept per window
  servers = {
    {
      name = "libera",
      host = "irc.libera.chat",
      port = 6697,
      tls = true,
      -- verify = false,         -- self-signed certificate: trust on first use
      autoconnect = true,
      autojoin = {},             -- channels, e.g. { "#lua", "#termina" }
      -- A registered nick: SASL login.
      -- sasl = { user = "mynick", pass = "secret" },
    },
    -- { name = "oftc", host = "irc.oftc.net", port = 6697, tls = true,
    --   autojoin = { "#debian" } },
  },
}
]]
end

-- Values the program keeps in a server config that are not settings.
local SKIP = {}

-- A readable dump of a value, indented.
local function dump(v, indent, out)
  local t = type(v)
  if t == "string" then out[#out + 1] = string.format("%q", v)
  elseif t == "number" or t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "table" then
    local n = #v
    local keys = {}
    for k in pairs(v) do
      if not (math.type(k) == "integer" and k >= 1 and k <= n) and not SKIP[k] then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local simple = true
    for _, x in ipairs(v) do if type(x) == "table" then simple = false end end
    if #keys == 0 and simple then
      out[#out + 1] = "{"
      for i, x in ipairs(v) do
        out[#out + 1] = (i > 1 and ", " or " ")
        dump(x, indent, out)
      end
      out[#out + 1] = n > 0 and " }" or "}"
      return
    end
    local inner = indent .. "  "
    out[#out + 1] = "{\n"
    for _, k in ipairs(keys) do
      out[#out + 1] = inner
      out[#out + 1] = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. string.format("%q", k) .. "]")
      out[#out + 1] = " = "
      dump(v[k], inner, out)
      out[#out + 1] = ",\n"
    end
    for _, x in ipairs(v) do
      out[#out + 1] = inner
      dump(x, inner, out)
      out[#out + 1] = ",\n"
    end
    out[#out + 1] = indent .. "}"
  else
    out[#out + 1] = "nil"
  end
end

function M.load()
  if not fs.exists(M.PATH) then
    local nick = "termina" .. math.random(999)
    fs.mkdir("/etc")
    fs.write(M.PATH, template(nick))
  end
  local src = fs.read(M.PATH) or ""
  local f, err = load(src, "=" .. M.PATH, "t", {})
  if not f then return nil, err end
  local ok, v = pcall(f)
  if not ok then return nil, v end
  if type(v) ~= "table" then return nil, M.PATH .. " does not return a table" end
  v.nick = type(v.nick) == "string" and v.nick ~= "" and v.nick or "termina"
  v.servers = type(v.servers) == "table" and v.servers or {}
  for i = #v.servers, 1, -1 do
    local s = v.servers[i]
    if type(s) ~= "table" or type(s.host) ~= "string" then
      table.remove(v.servers, i)
    else
      s.port = tonumber(s.port) or (s.tls == false and 6667 or 6697)
      if s.tls == nil then s.tls = s.port ~= 6667 end
      s.name = s.name or s.host
      s.autojoin = type(s.autojoin) == "table" and s.autojoin or {}
    end
  end
  M.data = v
  return v
end

function M.save()
  -- The nick, user and realname filled into each server from the top
  -- level are not written back when they did not change.
  local d = M.data
  local copy = {}
  for k, v in pairs(d) do copy[k] = v end
  copy.servers = {}
  for _, s in ipairs(d.servers) do
    local c = {}
    for k, v in pairs(s) do c[k] = v end
    if c.user == d.user or c.user == s.nick or c.user == d.nick then c.user = nil end
    if c.nick == d.nick then c.nick = nil end
    if c.realname == d.realname then c.realname = nil end
    copy.servers[#copy.servers + 1] = c
  end
  local out = {"-- Termina IRC settings. Edit, then restart irc (or /save from irc).\nreturn "}
  dump(copy, "", out)
  out[#out + 1] = "\n"
  return pcall(fs.write, M.PATH, table.concat(out))
end

return M
