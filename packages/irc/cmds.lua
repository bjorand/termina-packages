-- irc.cmds: what is typed in the input line. Text is sent to the channel
-- or person of the window on screen; a line starting with / is a command
-- (// sends a line that starts with /).
local proto = require "irc.proto"
local model = require "irc.model"
local Conn = require "irc.conn"
local config = require "irc.config"
local ui = require "irc.ui"

local M = {}
M.quit = false

local function say(text, kind)
  model.add(model.active, {kind = kind or "event", text = text})
end

local function err(text) say(text, "error") end

-- The connection of the window on screen, ready to send.
local function conn(needReady)
  local w = model.active
  local c = w and w.conn
  if not c then err("No server here: /connect a server first") return nil end
  if needReady and c.state ~= "ready" then err("Not connected to " .. c:label()) return nil end
  return c
end

-- Sends a message (or an action) to target, and shows it.
local function send(c, target, text, action)
  local win = model.find(c, target)
  if not win then
    win = model.open(c, c:isChannel(target) and "channel" or "query", target)
  end
  for _, part in ipairs(proto.split(text, 400 - #target)) do
    if action then
      c:sendf("PRIVMSG", target, proto.mkctcp("ACTION", part))
      model.add(win, {kind = "action", nick = c.nick, text = part, self = true})
    else
      c:sendf("PRIVMSG", target, part)
      model.add(win, {kind = "self", nick = c.nick, text = part})
    end
  end
  return win
end

-- "host[:port]" or a configured name -> server config (a new one for a host).
local function serverCfg(spec, tlsFlag)
  for _, s in ipairs(config.data.servers) do
    if s.name:lower() == spec:lower() then return s end
  end
  local host, port = spec:match("^(.-):%+?(%d+)$")
  host = host or spec
  port = tonumber(port) or (tlsFlag == false and 6667 or 6697)
  local tls = port ~= 6667 and port ~= 6668
  if tlsFlag ~= nil then tls = tlsFlag end
  local name = host:match("^irc%.([^.]+)%.") or host:match("^([^.]+)") or host
  return {name = name, host = host, port = port, tls = tls, autojoin = {}}
end

local function connFor(cfg)
  for _, c in ipairs(model.conns) do
    if c.cfg == cfg or (c.cfg.host == cfg.host and c.cfg.port == cfg.port) then return c end
  end
end

-- Fills the defaults of the config (nick, user...) into a server config.
local function complete(s)
  local d = config.data
  s.nick = s.nick or d.nick
  s.user = s.user or d.user or s.nick
  s.realname = s.realname or d.realname
  return s
end

function M.connect(cfg)
  complete(cfg)
  local c = connFor(cfg)
  if c then
    if c.state == "idle" then c:start() end
    model.select(c.status)
    return c
  end
  c = Conn.new(cfg)
  c:start()
  model.select(c.status)
  return c
end

local C = {}
local HELP = {
  {"connect name|host[:port] [-tls|+tls]", "connect to a server (TLS unless port 6667)"},
  {"disconnect [message]", "leave the server of this window"},
  {"reconnect", "connect again to the server of this window"},
  {"join #channel [key]", "join a channel"},
  {"part [#channel] [message]", "leave a channel"},
  {"msg nick|#channel text", "send a message"},
  {"query nick [text]", "open a private conversation"},
  {"me action", "an action: * you waves"},
  {"notice target text", "send a notice"},
  {"nick new", "change your nick"},
  {"topic [text]", "show or change the topic"},
  {"names", "list the people in the channel"},
  {"whois nick", "who someone is"},
  {"away [message]", "set or clear (no message) away"},
  {"close", "close this window (leaves the channel)"},
  {"win n|name", "go to window n, or the first one with name in it"},
  {"clear", "clear this window"},
  {"layout [auto|tall|wide]", "portrait or landscape screen (auto: by width)"},
  {"nicks", "show or hide the nick list (Alt+N)"},
  {"raw line", "send a line as is (also /quote)"},
  {"trust", "accept a changed certificate (server with verify = false)"},
  {"save", "save the servers and channels to " .. config.PATH},
  {"quit [message]", "leave every server and exit"},
}

function C.help()
  say("Commands:")
  for _, h in ipairs(HELP) do say("/" .. h[1] .. " - " .. h[2]) end
  say("Keys: Alt+1..9,0 window, Alt+W list of windows, Alt+Left/Right or Ctrl+P/N previous/next, " ..
    "Alt+A next busy window, Alt+N nick list, PgUp/PgDn scroll, Tab completes nicks, Up/Down history, " ..
    "Ctrl+V paste, Ctrl+Q quit. Click a window in the bar, or a nick to talk to them.")
  say("Unknown commands are sent to the server as they are: /mode #c +i -> MODE #c +i.")
end

function C.connect(args)
  local spec, flag = args:match("^(%S+)%s*(%S*)")
  if not spec then
    local names = {}
    for _, s in ipairs(config.data.servers) do names[#names + 1] = s.name end
    say("Servers: " .. (#names > 0 and table.concat(names, ", ") or "none") .. " - /connect name|host[:port]")
    return
  end
  local tls = nil
  if flag == "-tls" or flag == "-notls" then tls = false elseif flag == "+tls" or flag == "-ssl" then tls = true end
  M.connect(serverCfg(spec, tls))
end
C.server = C.connect

function C.disconnect(args)
  local c = conn()
  if c then c:quit(args ~= "" and args or nil) end
end

function C.reconnect()
  local c = conn()
  if not c then return end
  if c.sock then c:sendf("QUIT", "Reconnecting") end
  c.stopped = false
  c:drop("Reconnecting", false)
  c:start()
end

function C.join(args)
  local c = conn(true)
  if not c then return end
  local ch, key = args:match("^(%S+)%s*(%S*)")
  if not ch then err("/join #channel") return end
  if not c:isChannel(ch) then ch = "#" .. ch end
  c.wantWindow = ch
  local w = model.find(c, ch)
  if w then model.select(w) end
  if key ~= "" then c:sendf("JOIN", ch, key) else c:sendf("JOIN", ch) end
end
C.j = C.join

function C.part(args)
  local c = conn(true)
  if not c then return end
  local ch, msg = args:match("^(%S+)%s*(.*)$")
  if not ch or not c:isChannel(ch) then
    ch, msg = model.active.name, args
    if model.active.kind ~= "channel" then err("/part #channel") return end
  end
  if msg ~= "" then c:sendf("PART", ch, msg) else c:sendf("PART", ch) end
end
C.leave = C.part

function C.msg(args)
  local c = conn(true)
  if not c then return end
  local target, text = args:match("^(%S+)%s+(.+)$")
  if not target then err("/msg nick|#channel text") return end
  send(c, target, text)
end

function C.query(args)
  local c = conn()
  if not c then return end
  local nick, text = args:match("^(%S+)%s*(.*)$")
  if not nick then err("/query nick") return end
  local w = model.open(c, "query", nick)
  model.select(w)
  if text ~= "" and c.state == "ready" then send(c, nick, text) end
end
C.q = C.query

function C.me(args)
  local c = conn(true)
  local w = model.active
  if not c or w.kind == "status" then err("/me works in a channel or a conversation") return end
  send(c, w.name, args, true)
end

function C.notice(args)
  local c = conn(true)
  if not c then return end
  local target, text = args:match("^(%S+)%s+(.+)$")
  if not target then err("/notice target text") return end
  c:sendf("NOTICE", target, text)
  say("-> -" .. target .. "- " .. text, "notice")
end

function C.nick(args)
  local c = conn()
  if not c then return end
  local nick = args:match("^(%S+)")
  if not nick then say("Your nick: " .. c.nick) return end
  if c.sock then c:sendf("NICK", nick) end
  c.cfg.nick = nick
  if c.state ~= "ready" then c.nick = nick end
end

function C.topic(args)
  local c = conn(true)
  local w = model.active
  if not c or w.kind ~= "channel" then err("/topic works in a channel") return end
  if args == "" then
    say("Topic: " .. (w.topic and w.topic ~= "" and w.topic or "(none)"))
  else
    c:sendf("TOPIC", w.name, args)
  end
end

function C.names()
  local c = conn(true)
  local w = model.active
  if not c or w.kind ~= "channel" then err("/names works in a channel") return end
  w.showNames = true
  c:sendf("NAMES", w.name)
end

function C.whois(args)
  local c = conn(true)
  if not c then return end
  local nick = args:match("^(%S+)") or (model.active.kind == "query" and model.active.name)
  if not nick then err("/whois nick") return end
  c:sendf("WHOIS", nick)
end

function C.away(args)
  local c = conn(true)
  if not c then return end
  if args ~= "" then c:sendf("AWAY", args) else c:send("AWAY") end
end

function C.close()
  local w = model.active
  if not w then return end
  local c = w.conn
  if w.kind == "channel" then
    if c and c.state == "ready" and w.joined then c:sendf("PART", w.name) end
    model.close(w)
  elseif w.kind == "query" then
    model.close(w)
  elseif c then
    -- The status window: leave the server and close all its windows.
    c:quit()
    for i = #model.windows, 1, -1 do
      if model.windows[i].conn == c then model.close(model.windows[i]) end
    end
    for i, x in ipairs(model.conns) do
      if x == c then table.remove(model.conns, i) break end
    end
  end
  if #model.windows == 0 then
    model.open(nil, "status", "irc")
    model.select(model.windows[1])
    C.help()
  end
end
C.wc = C.close

function C.win(args)
  local n = tonumber(args)
  if n and model.windows[n] then model.select(model.windows[n]) return end
  -- A name: the first window whose name (or network) contains it.
  local low = args:lower()
  if low ~= "" then
    for _, w in ipairs(model.windows) do
      local label = w.kind == "status" and w.conn and w.conn:label() or w.name
      if label:lower():find(low, 1, true) or w.name:lower():find(low, 1, true) then
        model.select(w)
        return
      end
    end
  end
  err("/win 1.." .. #model.windows .. " or a name")
end
C.w = C.win

function C.clear()
  local w = model.active
  if w then w.lines, w.scroll = {}, 0 end
  model.dirty = true
end

function C.layout(args)
  local m = args:lower()
  if m == "auto" or m == "tall" or m == "wide" then
    ui.mode = m
    config.data.layout = m ~= "auto" and m or nil
    ui.invalidate()
    model.dirty = true
  end
  say("Layout: " .. ui.mode .. (ui.mode == "auto" and (ui.tall() and " (tall)" or " (wide)") or "") ..
    " - /layout auto|tall|wide, /save to keep it")
end

-- The nick list column on the right, on and off (/save keeps it).
function C.nicks()
  ui.showNicks = not ui.showNicks
  config.data.nicklist = not ui.showNicks and false or nil
  model.dirty = true
end

function C.raw(args)
  local c = conn()
  if not c then return end
  if args == "" then err("/raw line") return end
  c:send(args)
  say("-> " .. args)
end
C.quote = C.raw

function C.trust()
  local c = conn()
  if not c or not c.pendingFp then err("No changed certificate to accept here") return end
  Conn.trust(c:hostport(), c.pendingFp)
  c.pendingFp = nil
  say("New certificate of " .. c:hostport() .. " trusted: /reconnect")
end

function C.save()
  -- Every server open now, with the channels joined, joins the config.
  local list = config.data.servers
  for _, c in ipairs(model.conns) do
    local found = false
    for _, s in ipairs(list) do if s == c.cfg then found = true end end
    if not found then list[#list + 1] = c.cfg end
    local chans = {}
    for _, w in ipairs(model.windows) do
      if w.conn == c and w.kind == "channel" and w.joined then chans[#chans + 1] = w.name end
    end
    c.cfg.autojoin = chans
    c.cfg.autoconnect = true
  end
  local ok, e = config.save()
  if ok then say("Saved to " .. config.PATH) else err("Cannot save: " .. tostring(e)) end
end

function C.quit(args)
  for _, c in ipairs(model.conns) do c:quit(args ~= "" and args or nil) end
  M.quit = true
end
C.exit = C.quit

function M.run(text)
  if text == "" then return end
  if text:sub(1, 1) == "/" and text:sub(2, 2) ~= "/" then
    local name, args = text:match("^/(%S*)%s*(.-)%s*$")
    name = name:lower()
    local f = C[name]
    if f then return f(args) end
    local c = conn(true)
    if c then
      c:send(name:upper() .. (args ~= "" and (" " .. args) or ""))
    end
    return
  end
  if text:sub(1, 2) == "//" then text = text:sub(2) end
  local w = model.active
  if not w or w.kind == "status" then
    err("This is a server window: /join a channel, or /msg someone")
    return
  end
  local c = conn(true)
  if c then send(c, w.name, text) end
end

-- Tab completion: commands after "/", channels after "#", else the nicks
-- of the window (the latest speakers first).
function M.complete(word, first)
  local out, seen = {}, {}
  local low = word:lower()
  local function try(s)
    if s:lower():sub(1, #low) == low and not seen[s:lower()] then
      seen[s:lower()] = true
      out[#out + 1] = s
    end
  end
  if first and word:sub(1, 1) == "/" then
    local names = {}
    for n in pairs(C) do names[#names + 1] = "/" .. n end
    table.sort(names)
    for _, n in ipairs(names) do try(n) end
    return out
  end
  local w = model.active
  if not w then return out end
  if w.conn and w.conn:isChannel(word) then
    for _, x in ipairs(model.windows) do
      if x.conn == w.conn and x.kind == "channel" then try(x.name) end
    end
    return out
  end
  for i = #w.lines, math.max(1, #w.lines - 100), -1 do
    local n = w.lines[i].nick
    if n and w.kind == "channel" and model.getNick(w, n) then try(n) end
  end
  if w.kind == "channel" then
    for _, n in ipairs(model.sortedNicks(w)) do try(n.nick) end
  elseif w.kind == "query" then
    try(w.name)
  end
  return out
end

return M
