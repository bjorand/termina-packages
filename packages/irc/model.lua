-- irc.model: the windows (a status window per server, channels, private
-- queries), their lines and nick lists, and which one is on screen.
local proto = require "irc.proto"
local sys = termina.sys

local M = {
  windows = {},     -- in screen order: each server's status window, then its channels and queries
  active = nil,     -- the window on screen
  conns = {},       -- the connections, in order
  dirty = true,     -- something on screen changed
  scrollback = 300, -- lines kept per window
  redraw = nil,     -- function(): draws at once (set by the main program)
}

-- Activity levels of a window not on screen.
M.NONE, M.EVENT, M.MSG, M.HILITE = 0, 1, 2, 3

-- "HH:MM" and minutes since midnight (nil without network time).
local function clock()
  local h, m = sys.time()
  if not h then return "--:--", nil end
  return string.format("%02d:%02d", h, m), h * 60 + m
end

-- Kinds of lines that are said by someone, and grouped under one header
-- in the tall layout.
local SAID = {msg = true, self = true, notice = true}
local GROUP_MINUTES = 5

local function key(conn, name)
  return proto.lower(name, conn and conn.isup.casemapping)
end

function M.index(win)
  for i, w in ipairs(M.windows) do
    if w == win then return i end
  end
end

function M.find(conn, name)
  local k = key(conn, name)
  for _, w in ipairs(M.windows) do
    if w.conn == conn and w.key == k then return w end
  end
end

-- open(conn, kind, name) -> the window, created after the last window of
-- the same connection when it does not exist. kind: "status", "channel",
-- "query".
function M.open(conn, kind, name)
  -- A status window never matches a name: a person may be called as
  -- the server.
  local w = kind ~= "status" and M.find(conn, name)
  if w then return w end
  w = {conn = conn, kind = kind, name = name, key = kind == "status" and "\0" or key(conn, name),
       lines = {}, act = M.NONE, scroll = 0, nicks = {}, nickCount = 0}
  local at = #M.windows + 1
  if conn then
    for i = #M.windows, 1, -1 do
      if M.windows[i].conn == conn then at = i + 1 break end
    end
  end
  table.insert(M.windows, at, w)
  if not M.active then M.active = w end
  M.dirty = true
  return w
end

function M.close(win)
  local i = M.index(win)
  if not i then return end
  table.remove(M.windows, i)
  if M.active == win then
    M.active = M.windows[math.max(1, i - 1)] or M.windows[1]
    if M.active then M.active.act = M.NONE end
  end
  M.dirty = true
end

function M.select(win)
  if not win then return end
  M.active = win
  win.act = M.NONE
  M.dirty = true
end

function M.rename(win, name)
  win.name = name
  win.key = key(win.conn, name)
  M.dirty = true
end

-- add(win, line): line = {kind, nick, text, hl}. kind: "msg", "self",
-- "action", "notice", "join", "part", "event", "error". The time is added
-- here. Returns the line.
function M.add(win, line)
  if not win then return end
  line.time, line.mins = clock()
  local lines = win.lines
  -- cont: the same person goes on talking (no new header); gap: a new
  -- header after other lines (a blank row before it).
  local prev = lines[#lines]
  if SAID[line.kind] and prev then
    local dt = line.mins and prev.mins and (line.mins - prev.mins) % 1440 or 0
    line.cont = prev.kind == line.kind and prev.nick == line.nick and dt < GROUP_MINUTES
    line.gap = not line.cont
  elseif prev and SAID[prev.kind] then
    line.gap = true -- an event right after someone's text
  end
  lines[#lines + 1] = line
  if #lines > M.scrollback then table.remove(lines, 1) end
  if win == M.active then
    -- Scrolled up: stay on the same text while new lines come in.
    if win.scroll > 0 then win.scroll = win.scroll + 1 end
  else
    local level = line.hl and M.HILITE
      or (line.kind == "msg" or line.kind == "action" or line.kind == "notice") and M.MSG
      or line.kind ~= "self" and M.EVENT or M.NONE
    if win.kind == "query" and level == M.MSG then level = M.HILITE end
    if level > win.act then win.act = level end
  end
  M.dirty = true
  return line
end

-- info(text [, conn]): a line in the status window of conn, or in the
-- window on screen when there is no connection.
function M.info(text, conn, kind)
  local win = conn and conn.status or M.active
  return M.add(win, {kind = kind or "event", text = text})
end

-- Where to show a reply that is not tied to a channel (WHOIS, errors): the
-- window on screen when it belongs to conn, else conn's status window.
function M.here(conn)
  if M.active and M.active.conn == conn then return M.active end
  return conn.status
end

-- ------------------------------------------------------------------ nicks

-- Nicks of a channel: win.nicks[key] = {nick, pre}; pre holds the status
-- prefixes ("@", "+", "@+" with multi-prefix).
function M.setNick(win, nick, pre)
  local k = key(win.conn, nick)
  if not win.nicks[k] then win.nickCount = win.nickCount + 1 end
  win.nicks[k] = {nick = nick, pre = pre or ""}
  win.sorted = nil
  if win == M.active then M.dirty = true end
end

function M.dropNick(win, nick)
  local k = key(win.conn, nick)
  if not win.nicks[k] then return false end
  win.nicks[k] = nil
  win.nickCount = win.nickCount - 1
  win.sorted = nil
  if win == M.active then M.dirty = true end
  return true
end

function M.getNick(win, nick)
  return win.nicks[key(win.conn, nick)]
end

function M.clearNicks(win)
  win.nicks, win.nickCount, win.sorted = {}, 0, nil
  if win == M.active then M.dirty = true end
end

-- The nick list in display order: by highest status, then by name.
function M.sortedNicks(win)
  if win.sorted then return win.sorted end
  local prefixes = win.conn and win.conn.isup.prefixes or "@+"
  local list = {}
  for _, n in pairs(win.nicks) do
    local rank = #prefixes + 1
    if n.pre ~= "" then rank = prefixes:find(n.pre:sub(1, 1), 1, true) or rank end
    list[#list + 1] = {nick = n.nick, pre = n.pre, rank = rank, low = n.nick:lower()}
  end
  table.sort(list, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.low < b.low
  end)
  win.sorted = list
  return list
end

return M
