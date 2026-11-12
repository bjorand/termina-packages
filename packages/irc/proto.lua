-- irc.proto: the IRC message format (RFC 1459 / 2812 and IRCv3 tags),
-- without any I/O, so that it can be tested on a PC.
local M = {}

-- parse(line) -> {tags, prefix, nick, user, host, cmd, params} or nil.
-- cmd is upper case ("PRIVMSG", "001"); params holds the middle parameters
-- and the trailing one last, as a plain list.
function M.parse(line)
  line = line:gsub("[\r\n]+$", "")
  if line == "" then return nil end
  local m = {params = {}}
  local pos = 1
  if line:sub(1, 1) == "@" then
    local raw, p = line:match("^@(%S+) *()")
    if not raw then return nil end
    m.tags = {}
    for kv in raw:gmatch("[^;]+") do
      local k, v = kv:match("^([^=]+)=?(.*)$")
      if k then
        v = v:gsub("\\(.)", {[":"] = ";", s = " ", ["\\"] = "\\", r = "\r", n = "\n"})
        m.tags[k] = v
      end
    end
    pos = p
  end
  if line:sub(pos, pos) == ":" then
    local prefix, p = line:match("^:(%S+) *()", pos)
    if not prefix then return nil end
    m.prefix = prefix
    m.nick, m.user, m.host = prefix:match("^([^!@]+)!?([^@]*)@?(.*)$")
    if m.user == "" then m.user = nil end
    if m.host == "" then m.host = nil end
    pos = p
  end
  local cmd, p = line:match("^(%S+) *()", pos)
  if not cmd then return nil end
  m.cmd = cmd:upper()
  pos = p
  while pos <= #line do
    if line:sub(pos, pos) == ":" then
      m.params[#m.params + 1] = line:sub(pos + 1)
      break
    end
    local arg, q = line:match("^(%S+) *()", pos)
    if not arg then break end
    m.params[#m.params + 1] = arg
    pos = q
  end
  return m
end

-- fmt(cmd, ...) -> the line to send, without CRLF. The last parameter gets
-- a colon when it needs one (empty, spaces, or starting with ':').
function M.fmt(cmd, ...)
  local n = select("#", ...)
  local out = {cmd}
  for i = 1, n do
    local a = tostring((select(i, ...)))
    a = a:gsub("[\r\n%z]", " ")
    if i == n and (a == "" or a:find(" ", 1, true) or a:sub(1, 1) == ":") then
      a = ":" .. a
    end
    out[#out + 1] = a
  end
  return table.concat(out, " ")
end

-- CTCP: ctcp(text) -> command, argument for "\1CMD arg\1", or nil.
function M.ctcp(text)
  local body = text:match("^\1(.-)\1?$")
  if not body then return nil end
  local c, arg = body:match("^(%S+) ?(.*)$")
  if not c then return nil end
  return c:upper(), arg
end

function M.mkctcp(cmd, arg)
  return "\1" .. cmd .. (arg and arg ~= "" and (" " .. arg) or "") .. "\1"
end

-- The 16 mIRC colors as Termina attribute foregrounds (CGA order).
local MIRC = {[0] = 15, 0, 1, 2, 12, 4, 5, 6, 14, 10, 3, 11, 9, 13, 8, 7}

-- format(text, base) -> plain, attrs: the text without mIRC formatting
-- codes, and a string of one attribute byte per byte of plain (as
-- term.putattr takes them). Colors (^C fg[,bg]), bold (^B, brightens),
-- reverse (^V) and reset (^O) are kept; italics, underline and the like
-- only disappear.
function M.format(text, base)
  if not text:find("[\2\3\15\17\22\29\30\31]") then
    return text, string.rep(string.char(base), #text)
  end
  local out, attrs = {}, {}
  local fg, bg = base & 0x0F, base >> 4
  local bold, rev = false, false
  local cfg, cbg -- nil: the base colors
  local i = 1
  local function attr()
    local f, b = cfg or fg, cbg or bg
    if bold and f < 8 then f = f + 8 end
    if rev then f, b = b, f end
    return string.char((b & 0x0F) * 16 + (f & 0x0F))
  end
  while i <= #text do
    local c = text:byte(i)
    if c == 2 then bold = not bold; i = i + 1
    elseif c == 22 then rev = not rev; i = i + 1
    elseif c == 15 then bold, rev, cfg, cbg = false, false, nil, nil; i = i + 1
    elseif c == 3 then
      local f, b, nexti = text:match("^(%d%d?),(%d%d?)()", i + 1)
      if not f then
        f, nexti = text:match("^(%d%d?)()", i + 1)
      end
      if f then
        local fn = tonumber(f)
        cfg = MIRC[fn] or cfg
        if b then cbg = (MIRC[tonumber(b)] or 0) & 7 end
        i = nexti
      else
        cfg, cbg = nil, nil
        i = i + 1
      end
    elseif c == 17 or c == 29 or c == 30 or c == 31 then i = i + 1
    else
      local j = text:find("[\2\3\15\17\22\29\30\31]", i) or #text + 1
      local chunk = text:sub(i, j - 1)
      out[#out + 1] = chunk
      attrs[#attrs + 1] = string.rep(attr(), #chunk)
      i = j
    end
  end
  return table.concat(out), table.concat(attrs)
end

-- strip(text): the text without any formatting code.
function M.strip(text)
  return (M.format(text, 7))
end

-- ISUPPORT (005) tokens into the server table isup: PREFIX=(ov)@+ gives
-- isup.modes = "ov", isup.prefixes = "@+"; CHANTYPES, NETWORK...
function M.isupport(isup, params)
  for i = 2, #params - 1 do
    local k, v = params[i]:match("^([^=]+)=?(.*)$")
    if k then
      if k == "PREFIX" then
        local modes, pre = v:match("^%((.-)%)(.*)$")
        if modes then isup.modes, isup.prefixes = modes, pre end
      elseif k == "CHANTYPES" then isup.chantypes = v
      elseif k == "NETWORK" then isup.network = v
      elseif k == "CASEMAPPING" then isup.casemapping = v
      end
    end
  end
end

-- Lower case as IRC compares names: rfc1459 maps []\~ to {}|^ as well.
function M.lower(s, casemapping)
  s = s:lower()
  if casemapping ~= "ascii" then s = s:gsub("[%[%]\\~]", {["["] = "{", ["]"] = "}", ["\\"] = "|", ["~"] = "^"}) end
  return s
end

function M.ischannel(name, chantypes)
  local c = name:sub(1, 1)
  return c ~= "" and (chantypes or "#&"):find(c, 1, true) ~= nil
end

-- A nick with its status prefixes ("@+nick") -> nick, prefixes.
function M.splitprefix(name, prefixes)
  prefixes = prefixes or "@+"
  local i = 1
  while i <= #name and prefixes:find(name:sub(i, i), 1, true) do i = i + 1 end
  return name:sub(i), name:sub(1, i - 1)
end

-- Base64, for SASL PLAIN.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function M.base64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    local q = {}
    for k = 3, 0, -1 do
      local v = (n >> (k * 6)) & 63
      q[#q + 1] = B64:sub(v + 1, v + 1)
    end
    if not b then q[3], q[4] = "=", "="
    elseif not c then q[4] = "=" end
    out[#out + 1] = table.concat(q)
  end
  return table.concat(out)
end

-- Splits a long message so that each PRIVMSG line stays under the 512
-- bytes of the protocol (room left for the prefix the server adds), on a
-- space when there is one, never inside a UTF-8 character.
function M.split(text, max)
  max = max or 400
  local parts = {}
  while #text > max do
    local cut = max
    local sp = text:sub(1, max):match(".*() ")
    if sp and sp > max // 2 then cut = sp - 1
    else
      while cut > 1 and (text:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
    end
    parts[#parts + 1] = text:sub(1, cut)
    text = text:sub(cut + 1):gsub("^ ", "")
  end
  parts[#parts + 1] = text
  return parts
end

return M
