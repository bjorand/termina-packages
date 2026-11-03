-- orbit.proto: Gemini URLs, requests and known hosts.
-- A request is one TLS connection: the client sends the URL and CRLF, the
-- server answers "<status> <meta>" CRLF, then the body (status 2x only) and
-- closes. Certificates are mostly self-signed: the first one seen for a host
-- is remembered in known_hosts and later ones are compared with it.
local M = {}

M.PORT = 1965
M.DIR = "/.orbit"
local KNOWN = M.DIR .. "/known_hosts"
local CONNECT_MS = 8000
local IDLE_MS = 15000       -- give up when nothing arrives for that long
local MAX_HEADER = 1029     -- 2 digits, space, 1024 bytes of meta, CRLF

-- --------------------------------------------------------------------- URLs

-- parse(url) -> {scheme, host, port, path, query} (query keeps its "?"), or nil.
function M.parse(url)
  local scheme, rest = url:match("^(%a[%w+.-]*):(.*)$")
  if not scheme then return nil end
  local u = {scheme = scheme:lower()}
  local auth, tail = rest:match("^//([^/?#]*)(.*)$")
  if auth then
    auth = auth:gsub("^.*@", "")
    local h, p = auth:match("^(.-):(%d+)$")
    u.host, u.port = (h or auth):lower(), tonumber(p)
    rest = tail
  end
  rest = rest:gsub("#.*$", "")
  u.path, u.query = rest:match("^([^?]*)(.*)$")
  return u
end

function M.format(u)
  local s = u.scheme .. ":"
  if u.host then
    s = s .. "//" .. u.host
    if u.port and not (u.scheme == "gemini" and u.port == M.PORT) then s = s .. ":" .. u.port end
  end
  return s .. u.path .. u.query
end

-- Removes "." and ".." segments (RFC 3986, 5.2.4).
local function removeDots(path)
  local out = {}
  local abs = path:sub(1, 1) == "/"
  local segs = {}
  for seg in (path .. "/"):gmatch("([^/]*)/") do segs[#segs + 1] = seg end
  if abs then table.remove(segs, 1) end
  local trailing = false
  for i, seg in ipairs(segs) do
    local last = i == #segs
    if seg == ".." then
      if #out > 0 then table.remove(out) end
      trailing = last
    elseif seg == "." then
      trailing = last
    else
      out[#out + 1] = seg
      trailing = false
    end
  end
  local s = table.concat(out, "/")
  if trailing and #out > 0 then s = s .. "/" end
  return (abs and "/" or "") .. s
end

-- resolve(base, ref) -> absolute URL of the link ref found on page base.
function M.resolve(base, ref)
  ref = ref:gsub("^%s+", ""):gsub("%s+$", "")
  if ref:match("^%a[%w+.-]*:") then return ref end
  local b = M.parse(base)
  if not b then return ref end
  if ref:sub(1, 2) == "//" then return b.scheme .. ":" .. ref end
  local r = M.parse("x:" .. ref)
  local u = {scheme = b.scheme, host = b.host, port = b.port}
  if r.path == "" then
    u.path, u.query = b.path, r.query ~= "" and r.query or b.query
  elseif r.path:sub(1, 1) == "/" then
    u.path, u.query = removeDots(r.path), r.query
  else
    local dir = b.path:match("^(.*/)") or "/"
    u.path, u.query = removeDots(dir .. r.path), r.query
  end
  return M.format(u)
end

-- What the user typed in the address prompt -> a full URL.
function M.normalize(s)
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if not s:match("^%a[%w+.-]*://") then s = "gemini://" .. s end
  local u = M.parse(s)
  if not u then return s end
  if u.host and u.path == "" then u.path = "/" end
  return M.format(u)
end

function M.encode(s)
  return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- ---------------------------------------------------------------- known hosts

local known

local function loadKnown()
  if known then return known end
  known = {}
  if fs.exists(KNOWN) then
    for line in (fs.read(KNOWN) or ""):gmatch("[^\n]+") do
      local host, fp = line:match("^(%S+)%s+(%x+)")
      if host then known[host] = fp end
    end
  end
  return known
end

function M.trust(hostport, fp)
  local k = loadKnown()
  k[hostport] = fp
  local lines = {}
  for h, f in pairs(k) do lines[#lines + 1] = h .. " " .. f end
  table.sort(lines)
  fs.mkdir(M.DIR)
  fs.write(KNOWN, table.concat(lines, "\n") .. "\n")
end

-- "new", "ok" or "changed" (with the fingerprint seen before).
function M.check(hostport, fp)
  local old = loadKnown()[hostport]
  if not old then return "new" end
  if old == fp then return "ok" end
  return "changed", old
end

-- ------------------------------------------------------------------ requests

-- open(url [, status]) -> response {status, meta, url, host, fingerprint},
-- or nil, message, extra. The body is read with response:body() or
-- response:save(). status(text) shows progress. A certificate that differs
-- from the remembered one is refused with nil, "changed", {host, old, new}.
function M.open(url, status)
  local u = M.parse(url)
  if not u or u.scheme ~= "gemini" or not u.host or u.host == "" then
    return nil, "not a gemini:// URL"
  end
  local port = u.port or M.PORT
  local hostport = port == M.PORT and u.host or (u.host .. ":" .. port)
  if status then status("Connecting to " .. hostport .. "...") end
  local sock, err = net.connect(u.host, port, {timeout = CONNECT_MS, tls = true})
  if not sock then return nil, err end
  local fp = sock:fingerprint()
  if fp then
    local state, old = M.check(hostport, fp)
    if state == "changed" then
      sock:close()
      return nil, "changed", {host = hostport, old = old, new = fp, url = url}
    elseif state == "new" then
      M.trust(hostport, fp)
    end
  end
  sock:send(url .. "\r\n")
  if status then status("Waiting for " .. hostport .. "...") end

  local buf, last = "", sys.millis()
  while true do
    local data = sock:recv(1024)
    if not data then break end
    if #data > 0 then
      buf = buf .. data
      last = sys.millis()
      if buf:find("\r?\n") or #buf > MAX_HEADER then break end
    elseif sys.millis() - last > IDLE_MS then
      sock:close()
      return nil, "timeout"
    else
      sys.sleep(10)
    end
  end
  local header, rest = buf:match("^(.-)\r?\n(.*)$")
  local code, meta = (header or ""):match("^(%d%d)[ \t]*(.*)$")
  if not code then
    sock:close()
    return nil, #buf == 0 and "empty answer" or "bad answer from the server"
  end

  local r = {status = tonumber(code), meta = meta, url = url, host = hostport,
             fingerprint = fp, sock = sock, rest = rest}

  -- body(max) -> text, truncated: everything up to max bytes.
  function r:body(max)
    local parts, n = {self.rest}, #self.rest
    local t0, idle = sys.millis(), sys.millis()
    while n < max do
      local data = self.sock:recv(4096)
      if not data then break end
      if #data > 0 then
        parts[#parts + 1] = data
        n = n + #data
        idle = sys.millis()
        if status and sys.millis() - t0 > 200 then
          status(string.format("Receiving %d KB...", n // 1024))
          t0 = sys.millis()
        end
      elseif sys.millis() - idle > IDLE_MS then
        break
      else
        sys.sleep(10)
      end
    end
    self:close()
    local s = table.concat(parts)
    if #s > max then return s:sub(1, max), true end
    return s, n >= max
  end

  -- save(path) -> bytes written, or nil, message.
  function r:save(path)
    local f = fs.open(path, "w")
    if not f then
      self:close()
      return nil, "cannot write " .. path
    end
    local n, idle = #self.rest, sys.millis()
    f:write(self.rest)
    while true do
      local data = self.sock:recv(4096)
      if not data then break end
      if #data > 0 then
        f:write(data)
        n = n + #data
        idle = sys.millis()
        if status then status(string.format("Saving %d KB...", n // 1024)) end
      elseif sys.millis() - idle > IDLE_MS then
        break
      else
        sys.sleep(10)
      end
    end
    f:close()
    self:close()
    return n
  end

  function r:close()
    if self.sock then self.sock:close() end
    self.sock = nil
  end

  return r
end

return M
