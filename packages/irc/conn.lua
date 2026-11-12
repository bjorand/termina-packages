-- irc.conn: one connection to a server. It registers (CAP, SASL PLAIN,
-- NICK/USER), answers PING, keeps the windows of its channels up to date
-- and reconnects after a drop, waiting longer each time.
local proto = require "irc.proto"
local model = require "irc.model"
local net, sys, fs = termina.net, termina.sys, termina.fs

local M = {}
M.__index = M

M.KNOWN = "/etc/irc.known"      -- TLS fingerprints seen: "host:port sha256"
M.VERSION = "Termina IRC 1.0.0"

local CONNECT_MS = 10000
local IDLE_PING_MS = 90000      -- this long without data: PING the server
local DEAD_MS = 180000          -- this long: the link is dead, reconnect
local RETRY_MIN, RETRY_MAX = 5000, 300000
local READS = 8                 -- reads of 2 KB at most per pass

-- ------------------------------------------------------------ known hosts

local known

local function loadKnown()
  if known then return known end
  known = {}
  if fs.exists(M.KNOWN) then
    for line in (fs.read(M.KNOWN) or ""):gmatch("[^\n]+") do
      local h, fp = line:match("^(%S+)%s+(%x+)")
      if h then known[h] = fp end
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
  fs.write(M.KNOWN, table.concat(lines, "\n") .. "\n")
end

-- ------------------------------------------------------------- lifecycle

-- new(cfg): cfg = {name, host, port, tls, nick, user, realname, pass,
-- sasl = {user, pass}, autojoin = {...}}. The connection starts at the
-- next pump().
function M.new(cfg)
  local c = setmetatable({cfg = cfg, isup = {}, buf = "", nick = cfg.nick,
                          state = "idle", retryAt = 0, backoff = RETRY_MIN}, M)
  c.status = model.open(c, "status", cfg.name)
  table.insert(model.conns, c)
  return c
end

function M:hostport()
  return self.cfg.host .. ":" .. self.cfg.port
end

-- The network's name for the screen: NETWORK from the server, else the
-- configured name.
function M:label()
  return self.isup.network or self.cfg.name
end

function M:send(line)
  if not self.sock then return false end
  local n = self.sock:send(line .. "\r\n")
  return n ~= nil
end

function M:sendf(cmd, ...)
  return self:send(proto.fmt(cmd, ...))
end

function M:start()
  self.stopped = false
  self.state = "waiting"
  self.retryAt = sys.millis()
end

-- drop(why [, retry]): closes the socket; retry schedules a new attempt.
function M:drop(why, retry)
  if self.sock then pcall(self.sock.close, self.sock) end
  self.sock, self.buf = nil, ""
  for _, w in ipairs(model.windows) do
    if w.conn == self and w.kind == "channel" and w.joined then
      w.joined, w.rejoin = false, true
      model.clearNicks(w)
      model.add(w, {kind = "error", text = "Disconnected from " .. self:label()})
    end
  end
  if retry and not self.stopped then
    self.state = "waiting"
    self.retryAt = sys.millis() + self.backoff
    model.info(string.format("%s - reconnecting in %d s", why, self.backoff // 1000), self, "error")
    self.backoff = math.min(RETRY_MAX, self.backoff * 2)
  else
    self.state = "idle"
    model.info(why, self, "error")
  end
end

-- quit(msg): leaves the server for good (until /connect).
function M:quit(msg)
  self.stopped = true
  if self.sock then
    self:sendf("QUIT", msg or "Termina 80")
    self:drop("Disconnected", false)
  else
    self.state = "idle"
  end
end

function M:connect()
  local cfg = self.cfg
  self.state = "connecting"
  model.info(string.format("Connecting to %s%s...", self:hostport(), cfg.tls and " (TLS)" or ""), self)
  if model.redraw then model.redraw() end -- connect blocks: show it first
  collectgarbage()
  local s, err = net.connect(cfg.host, cfg.port, {timeout = CONNECT_MS, tls = cfg.tls})
  if not s then
    self:drop("Cannot reach " .. self:hostport() .. ": " .. tostring(err), true)
    return
  end
  if cfg.tls then
    local fp = s:fingerprint()
    if fp then
      local old = loadKnown()[self:hostport()]
      if not old then
        M.trust(self:hostport(), fp)
        model.info("New certificate trusted: " .. fp:sub(1, 32) .. "...", self)
      elseif old ~= fp then
        pcall(s.close, s)
        self.pendingFp = fp
        self.stopped = true
        self:drop("The certificate of " .. self:hostport() .. " CHANGED (was " .. old:sub(1, 16) ..
          "..., now " .. fp:sub(1, 16) .. "...). Type /trust to accept it, then /reconnect", false)
        return
      end
    end
  end
  self.sock, self.buf = s, ""
  self.lastData, self.pinged = sys.millis(), false
  self.state = "registering"
  self.nick = cfg.nick
  self.isup = {}
  self.caps, self.capList = {}, {}
  self:send("CAP LS 302")
  if cfg.pass and cfg.pass ~= "" then self:sendf("PASS", cfg.pass) end
  self:sendf("NICK", self.nick)
  self:sendf("USER", cfg.user or cfg.nick, "0", "*", cfg.realname or cfg.nick)
  model.dirty = true
end

-- pump(): connects when it is time, reads what came in and handles it.
-- Returns true when something was received.
function M:pump()
  if not self.sock then
    if self.state == "waiting" and sys.millis() >= self.retryAt then self:connect() end
    return false
  end
  local data = self.sock:recv(2048)
  if data == nil then
    self:drop("Connection closed by " .. self:hostport(), not self.stopped)
    return true
  end
  local now = sys.millis()
  if #data == 0 then
    local idle = now - self.lastData
    if idle > DEAD_MS then
      self:drop("No answer from " .. self:hostport(), true)
    elseif idle > IDLE_PING_MS and not self.pinged then
      self.pinged = true
      self:sendf("PING", "termina")
    end
    return false
  end
  for _ = 2, READS do
    local more = self.sock and self.sock:recv(2048)
    if not more or #more == 0 then break end
    data = data .. more
  end
  self.lastData, self.pinged = now, false
  local buf = self.buf .. data
  local pos = 1
  while true do
    local nl = buf:find("\n", pos, true)
    if not nl then break end
    local line = buf:sub(pos, nl - 1)
    pos = nl + 1
    local m = proto.parse(line)
    if m then
      local ok, err = pcall(self.handle, self, m)
      if not ok then model.info("Bad message (" .. tostring(err) .. "): " .. line, self, "error") end
      if not self.sock then return true end
    end
  end
  self.buf = buf:sub(pos)
  if #self.buf > 8192 then self.buf = "" end -- no newline in 8 KB: not IRC
  return true
end

-- --------------------------------------------------------------- helpers

function M:isMe(nick)
  return nick and proto.lower(nick, self.isup.casemapping) == proto.lower(self.nick, self.isup.casemapping)
end

function M:isChannel(name)
  return proto.ischannel(name, self.isup.chantypes)
end

-- Whether text mentions my nick as a word.
function M:mentions(text)
  local low = proto.strip(text):lower()
  local me = self.nick:lower()
  local i = 1
  while true do
    local a, b = low:find(me, i, true)
    if not a then return false end
    local before, after = low:sub(a - 1, a - 1), low:sub(b + 1, b + 1)
    if not before:match("[%w_%-%[%]\\`^{}|]") and not after:match("[%w_%-%[%]\\`^{}|]") then
      return true
    end
    i = b + 1
  end
end

-- The windows of my channels where nick is.
function M:channelsOf(nick)
  local out = {}
  for _, w in ipairs(model.windows) do
    if w.conn == self and w.kind == "channel" and model.getNick(w, nick) then out[#out + 1] = w end
  end
  return out
end

local function rest(params, from)
  return table.concat(params, " ", from)
end

-- ------------------------------------------------------------- handlers

local H = {}

function H.PING(c, m) c:sendf("PONG", m.params[1] or "") end
function H.PONG() end

function H.ERROR(c, m)
  model.info("Server error: " .. (m.params[1] or ""), c, "error")
end

-- Registration: capabilities and SASL.
function H.CAP(c, m)
  local sub = (m.params[2] or ""):upper()
  if sub == "LS" then
    local more = m.params[3] == "*" and #m.params >= 4
    for cap in (m.params[#m.params] or ""):gmatch("%S+") do
      c.capList[cap:match("^[^=]+")] = true
    end
    if more then return end
    local want = {}
    local sasl = c.cfg.sasl
    if c.capList["sasl"] and sasl and sasl.user and sasl.user ~= "" then want[#want + 1] = "sasl" end
    if c.capList["multi-prefix"] then want[#want + 1] = "multi-prefix" end
    if #want > 0 then c:sendf("CAP", "REQ", table.concat(want, " "))
    else c:send("CAP END") end
  elseif sub == "ACK" then
    local sasl = false
    for cap in (m.params[#m.params] or ""):gmatch("%S+") do
      c.caps[cap] = true
      if cap == "sasl" then sasl = true end
    end
    if sasl then c:send("AUTHENTICATE PLAIN")
    elseif c.state == "registering" then c:send("CAP END") end
  elseif sub == "NAK" then
    if c.state == "registering" then c:send("CAP END") end
  end
end

function H.AUTHENTICATE(c, m)
  if m.params[1] == "+" then
    local s = c.cfg.sasl
    c:sendf("AUTHENTICATE", proto.base64(s.user .. "\0" .. s.user .. "\0" .. (s.pass or "")))
  end
end

H["903"] = function(c) model.info("Logged in (SASL)", c); c:send("CAP END") end
local function saslFail(c, m)
  model.info("SASL login failed: " .. (m.params[#m.params] or ""), c, "error")
  c:send("CAP END")
end
H["902"], H["904"], H["905"], H["906"] = saslFail, saslFail, saslFail, saslFail
H["900"] = function(c, m) model.info(m.params[#m.params] or "", c) end

H["001"] = function(c, m)
  c.state = "ready"
  c.nick = m.params[1] or c.nick
  c.backoff = RETRY_MIN
  model.info(m.params[#m.params] or "Welcome", c)
  local joined = {}
  local function join(name)
    local k = proto.lower(name)
    if joined[k] then return end
    joined[k] = true
    local ch, chkey = name:match("^(%S+)%s*(%S*)$")
    if chkey ~= "" then c:sendf("JOIN", ch, chkey) else c:sendf("JOIN", ch) end
  end
  for _, ch in ipairs(c.cfg.autojoin or {}) do join(ch) end
  for _, w in ipairs(model.windows) do
    if w.conn == c and w.kind == "channel" and w.rejoin then join(w.name) end
  end
end

H["005"] = function(c, m)
  proto.isupport(c.isup, m.params)
  local cm = rest(m.params, 2):match("CHANMODES=(%S+)")
  if cm then
    local a, b, cc = cm:match("^([^,]*),([^,]*),([^,]*)")
    c.isup.argModes = (a or "") .. (b or "")
    c.isup.setArgModes = cc or ""
  end
  model.dirty = true
end

-- Nick taken while registering: add "_" and try again.
local function nickInUse(c, m)
  local tried = m.params[2] or c.nick
  if c.state ~= "ready" then
    local nick = tried .. "_"
    if #nick > 16 then nick = tried:sub(1, 12) .. tostring(math.random(999)) end
    c.nick = nick
    c:sendf("NICK", nick)
    model.info(tried .. " is taken, trying " .. nick, c)
  else
    model.add(model.here(c), {kind = "error", text = tried .. ": " .. (m.params[#m.params] or "nick in use")})
  end
end
H["433"], H["436"] = nickInUse, nickInUse
H["432"] = function(c, m)
  if c.state ~= "ready" then
    c.nick = "termina" .. math.random(9999)
    c:sendf("NICK", c.nick)
  end
  model.add(model.here(c), {kind = "error", text = rest(m.params, 2)})
end

-- MOTD and the welcome numerics: in the status window, as they are.
for _, n in ipairs({"002", "003", "004", "251", "252", "253", "254", "255", "265", "266",
                    "250", "372", "375", "376", "422"}) do
  H[n] = function(c, m)
    local text = #m.params > 2 and n ~= "372" and rest(m.params, 2) or m.params[#m.params]
    model.add(c.status, {kind = "event", text = text})
  end
end

-- Channels.
function H.JOIN(c, m)
  local ch = m.params[1]
  if not ch then return end
  if c:isMe(m.nick) then
    local w = model.open(c, "channel", ch)
    w.joined, w.rejoin = true, false
    w.namesDone = false
    model.clearNicks(w)
    model.rename(w, ch)
    if c.wantWindow and proto.lower(c.wantWindow) == proto.lower(ch) then
      model.select(w)
      c.wantWindow = nil
    end
    model.add(w, {kind = "join", text = "You joined " .. ch})
  else
    local w = model.find(c, ch)
    if not w then return end
    model.setNick(w, m.nick, "")
    model.add(w, {kind = "join", text = m.nick .. " (" .. (m.user or "") .. "@" .. (m.host or "") .. ") joined"})
  end
end

function H.PART(c, m)
  local w = model.find(c, m.params[1] or "")
  if not w then return end
  local why = m.params[2] and (" (" .. m.params[2] .. ")") or ""
  if c:isMe(m.nick) then
    w.joined = false
    model.clearNicks(w)
    model.add(w, {kind = "part", text = "You left " .. w.name .. why})
  else
    model.dropNick(w, m.nick)
    model.add(w, {kind = "part", text = m.nick .. " left" .. why})
  end
end

function H.KICK(c, m)
  local w = model.find(c, m.params[1] or "")
  if not w then return end
  local who, why = m.params[2] or "?", m.params[3] or ""
  if c:isMe(who) then
    w.joined = false
    model.clearNicks(w)
    model.add(w, {kind = "error", text = "You were kicked by " .. (m.nick or "?") .. " (" .. why .. ")", hl = true})
  else
    model.dropNick(w, who)
    model.add(w, {kind = "part", text = who .. " was kicked by " .. (m.nick or "?") .. " (" .. why .. ")"})
  end
end

function H.QUIT(c, m)
  local why = m.params[1] and (" (" .. m.params[1] .. ")") or ""
  for _, w in ipairs(c:channelsOf(m.nick)) do
    model.dropNick(w, m.nick)
    model.add(w, {kind = "part", text = m.nick .. " quit" .. why})
  end
  local q = model.find(c, m.nick or "")
  if q and q.kind == "query" then model.add(q, {kind = "part", text = m.nick .. " quit" .. why}) end
end

function H.NICK(c, m)
  local new = m.params[1]
  if not new or not m.nick then return end
  local me = c:isMe(m.nick)
  if me then
    c.nick = new
    model.info("You are now known as " .. new, c)
  end
  for _, w in ipairs(c:channelsOf(m.nick)) do
    local n = model.getNick(w, m.nick)
    model.dropNick(w, m.nick)
    model.setNick(w, new, n and n.pre)
    model.add(w, {kind = "event", text = m.nick .. " is now known as " .. new})
  end
  local q = model.find(c, m.nick)
  if q and q.kind == "query" then
    model.rename(q, new)
    model.add(q, {kind = "event", text = m.nick .. " is now known as " .. new})
  end
  model.dirty = true
end

function H.TOPIC(c, m)
  local w = model.find(c, m.params[1] or "")
  if not w then return end
  w.topic = m.params[2] or ""
  model.add(w, {kind = "event", text = (m.nick or "?") .. " changed the topic to: " .. w.topic})
end

H["332"] = function(c, m)
  local w = model.find(c, m.params[2] or "")
  if not w then return end
  w.topic = m.params[3] or ""
  model.add(w, {kind = "event", text = "Topic: " .. w.topic})
end
H["331"] = function(c, m)
  local w = model.find(c, m.params[2] or "")
  if w then w.topic = "" end
end
H["333"] = function() end

-- NAMES: "353 me = #chan :@op +voice nick".
H["353"] = function(c, m)
  local w = model.find(c, m.params[3] or "")
  if not w or w.kind ~= "channel" then
    model.add(model.here(c), {kind = "event", text = "Names " .. (m.params[3] or "") .. ": " .. (m.params[4] or "")})
    return
  end
  if w.namesDone then
    model.clearNicks(w)
    w.namesDone = false
  end
  for name in (m.params[4] or ""):gmatch("%S+") do
    local nick, pre = proto.splitprefix(name, c.isup.prefixes)
    nick = nick:match("^[^!]+")
    model.setNick(w, nick, pre)
  end
end
H["366"] = function(c, m)
  local w = model.find(c, m.params[2] or "")
  if w then
    w.namesDone = true
    if w.showNames then
      w.showNames = false
      local list = {}
      for _, n in ipairs(model.sortedNicks(w)) do list[#list + 1] = n.pre:sub(1, 1) .. n.nick end
      model.add(w, {kind = "event", text = #list .. " users: " .. table.concat(list, " ")})
    end
  end
end

-- Modes: the status ones (+o, +v...) change the nick list.
function H.MODE(c, m)
  local target = m.params[1] or ""
  local w = model.find(c, target)
  local text = rest(m.params, 2)
  if not w or not c:isChannel(target) then
    model.info("Mode " .. target .. " " .. text, c)
    return
  end
  local modes = c.isup.modes or "ov"
  local prefixes = c.isup.prefixes or "@+"
  local argModes = c.isup.argModes or "beIkq"
  local setArg = c.isup.setArgModes or "lfj"
  local add, ai = true, 3
  for ch in (m.params[2] or ""):gmatch(".") do
    if ch == "+" then add = true
    elseif ch == "-" then add = false
    else
      local mi = modes:find(ch, 1, true)
      if mi then
        local nick = m.params[ai]
        ai = ai + 1
        local n = nick and model.getNick(w, nick)
        if n then
          local p = prefixes:sub(mi, mi)
          local pre = n.pre:gsub("%" .. p, "")
          if add then pre = pre .. p end
          -- keep the prefixes in rank order
          local sorted = {}
          for i = 1, #prefixes do
            local q = prefixes:sub(i, i)
            if pre:find(q, 1, true) then sorted[#sorted + 1] = q end
          end
          model.setNick(w, n.nick, table.concat(sorted))
        end
      elseif argModes:find(ch, 1, true) or (add and setArg:find(ch, 1, true)) then
        ai = ai + 1
      end
    end
  end
  model.add(w, {kind = "event", text = (m.nick or "?") .. " sets mode " .. text})
end

-- Messages.
local function message(c, m, notice)
  local target, text = m.params[1] or "", m.params[2] or ""
  local from = m.nick or m.prefix or "?"
  local cmd, arg = proto.ctcp(text)
  if cmd and cmd ~= "ACTION" then
    if notice then
      model.add(model.here(c), {kind = "notice", nick = from, text = "CTCP " .. cmd .. " reply: " .. arg})
    else
      local reply
      if cmd == "VERSION" then reply = M.VERSION
      elseif cmd == "PING" then reply = arg
      elseif cmd == "TIME" then
        local h, mi, s, d, mo, y = sys.time()
        reply = h and string.format("%04d-%02d-%02d %02d:%02d:%02d", y, mo, d, h, mi, s) or "unknown"
      elseif cmd == "CLIENTINFO" then reply = "ACTION CLIENTINFO PING TIME VERSION"
      end
      if reply then c:sendf("NOTICE", from, proto.mkctcp(cmd, reply)) end
      model.add(c.status, {kind = "event", text = "CTCP " .. cmd .. " from " .. from})
    end
    return
  end
  local win
  local self = c:isMe(from)
  if c:isChannel(target) then
    win = model.find(c, target)
    if not win then win = model.open(c, "channel", target) end
  elseif notice and (not m.nick or not m.user or c.state ~= "ready") then
    win = c.status   -- server notices
  else
    local other = self and target or from
    win = model.find(c, other)
    if not win then
      win = notice and model.here(c) or model.open(c, "query", other)
    end
  end
  local hl = not self and c:mentions(text)
  if cmd == "ACTION" then
    model.add(win, {kind = "action", nick = from, text = arg, hl = hl, self = self})
  else
    model.add(win, {kind = notice and "notice" or (self and "self" or "msg"), nick = from, text = text, hl = hl})
  end
end

function H.PRIVMSG(c, m) message(c, m, false) end
function H.NOTICE(c, m) message(c, m, true) end

function H.INVITE(c, m)
  model.add(model.here(c), {kind = "event", text = (m.nick or "?") .. " invites you to " .. (m.params[2] or "?"), hl = true})
end

-- WHOIS and other replies: in the window on screen.
H["301"] = function(c, m) model.add(model.here(c), {kind = "event", text = (m.params[2] or "") .. " is away: " .. (m.params[3] or "")}) end
H["311"] = function(c, m)
  local p = m.params
  model.add(model.here(c), {kind = "event", text = string.format("%s (%s@%s): %s", p[2] or "", p[3] or "", p[4] or "", p[6] or "")})
end
H["312"] = function(c, m) model.add(model.here(c), {kind = "event", text = "  server: " .. (m.params[3] or "") .. " (" .. (m.params[4] or "") .. ")"}) end
H["317"] = function(c, m) model.add(model.here(c), {kind = "event", text = "  idle: " .. (tonumber(m.params[3]) or 0) // 60 .. " min"}) end
H["319"] = function(c, m) model.add(model.here(c), {kind = "event", text = "  channels: " .. (m.params[3] or "")}) end
H["330"] = function(c, m) model.add(model.here(c), {kind = "event", text = "  account: " .. (m.params[3] or "")}) end
H["318"] = function() end
H["305"] = function(c, m) model.info(m.params[#m.params] or "", c) end
H["306"] = H["305"]
H["324"] = function(c, m)
  local w = model.find(c, m.params[2] or "")
  if w then model.add(w, {kind = "event", text = "Modes: " .. rest(m.params, 3)}) end
end
H["329"] = function() end

-- dispatch: the handler, or a generic line for numerics and the rest.
function M:handle(m)
  local h = H[m.cmd]
  if h then return h(self, m) end
  local code = tonumber(m.cmd)
  if code then
    local text = rest(m.params, 2)
    local kind = (code >= 400 and code < 600) and "error" or "event"
    model.add(kind == "error" and model.here(self) or self.status, {kind = kind, text = text})
  else
    model.add(self.status, {kind = "event", text = m.cmd .. " " .. rest(m.params, 1)})
  end
end

return M
