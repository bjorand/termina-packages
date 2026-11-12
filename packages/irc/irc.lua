-- irc: a full-screen IRC client. Several servers at once, each with its
-- channels and private conversations in windows, TLS (trust on first use)
-- and SASL login. Settings: /etc/irc.conf (written on the first run).
--
--   irc                   connects to the servers marked autoconnect
--   irc host[:port] [#c]  connects to that server only (TLS unless 6667)
--
-- In the program, /help lists the commands and keys.
if not termina or not termina.net then
  print("irc needs TERMINA 4.0 or later")
  return
end
local term, key, sys = termina.term, termina.key, termina.sys

local config = require "irc.config"
local model = require "irc.model"
local input = require "irc.input"
local ui = require "irc.ui"
local cmds = require "irc.cmds"

local args = {...}
if #args == 0 and arg then args = {table.unpack(arg)} end
if args[1] == "-h" or args[1] == "--help" then
  print("usage: irc [host[:port] [#channel...]]")
  print("  settings in " .. config.PATH .. "; /help in the program")
  return
end

local data, err = config.load()
if not data then
  print("irc: " .. tostring(err))
  print("fix " .. config.PATH .. " or remove it to start over")
  return
end
model.scrollback = tonumber(data.scrollback) or model.scrollback
if data.layout == "tall" or data.layout == "wide" then ui.mode = data.layout end
if data.nicklist == false then ui.showNicks = false end

-- Several servers with their scrollback: more than the 1 MB of a program.
pcall(sys.memlimit, 2 * 1024 * 1024)

input.complete = cmds.complete
model.redraw = ui.draw

local function cycle(step, busy)
  local n = #model.windows
  if n == 0 then return end
  local i = model.index(model.active) or 1
  for _ = 1, n do
    i = (i - 1 + step) % n + 1
    local w = model.windows[i]
    if not busy or w.act > model.NONE then model.select(w) return end
  end
end

-- Alt+A: the busiest window first (highlights, then messages).
local function nextBusy()
  local best
  for _, w in ipairs(model.windows) do
    if w ~= model.active and w.act > model.NONE and (not best or w.act > best.act) then best = w end
  end
  if best then model.select(best) end
end

local function scroll(n)
  local w = model.active
  if not w then return end
  w.scroll = math.max(0, w.scroll + n)
  model.dirty = true
end

-- A window picked in the window list.
local function choose(win)
  ui.picker = nil
  model.dirty = true
  if win then model.select(win) end
end

-- Alt+W: the window list, open or closed.
local function windowList()
  if ui.picker then ui.picker = nil
  else ui.picker = {kind = "windows", sel = model.index(model.active) or 1} end
  model.dirty = true
end

-- Keys while the window list is open: move, pick or close. True when the
-- key was for the list.
local function pickerKey(e)
  local p = ui.picker
  if e.type == "char" then return true end
  if e.type ~= "key" then return false end
  local k, n = e.key, #ui.pickItems()
  if e.alt and k ~= "w" then
    ui.picker = nil -- another window: the list closes
    return false
  end
  if k == "esc" then ui.picker = nil
  elseif k == "enter" then choose(ui.pickItems()[p.sel])
  elseif k == "up" then p.sel = math.max(1, p.sel - 1)
  elseif k == "down" then p.sel = math.min(n, p.sel + 1)
  elseif k == "pgup" then p.sel = math.max(1, p.sel - 10)
  elseif k == "pgdn" then p.sel = math.min(n, p.sel + 10)
  elseif k == "home" then p.sel = 1
  elseif k == "end" then p.sel = n
  else return false end
  model.dirty = true
  return true
end

local function onKey(e)
  if e.type == "wheel" then
    if ui.picker then
      local n = #ui.pickItems()
      ui.picker.sel = math.max(1, math.min(n, ui.picker.sel + e.n))
      model.dirty = true
    else
      scroll(-e.n * 3)
    end
    return
  end
  if e.type == "mouse" then
    if not e.down or e.button ~= 0 then return end -- the left button
    local what, v = ui.hit(e.x, e.y)
    if what == "pick" then
      choose(v)
    elseif what == "tab" then
      ui.picker = nil
      model.select(v)
    elseif what == "nick" and model.active and model.active.conn then
      model.select(model.open(model.active.conn, "query", v))
    end
    model.dirty = true
    return
  end
  if ui.picker and pickerKey(e) then return end
  if e.type == "key" then
    local k = e.key
    if e.alt and k == "w" then windowList() return end
    if e.alt and k == "n" then cmds.run("/nicks") return end
    if e.alt and k:match("^%d$") then
      local n = tonumber(k)
      if n == 0 then n = 10 end
      if model.windows[n] then model.select(model.windows[n]) end
      return
    end
    if (e.alt and k == "left") or (e.ctrl and k == "p") then cycle(-1) return end
    if (e.alt and k == "right") or (e.ctrl and k == "n") then cycle(1) return end
    if e.alt and k == "a" then nextBusy() return end
    if e.ctrl and k == "q" then cmds.run("/quit") return end
    if e.ctrl and k == "l" then ui.invalidate() term.cls() model.dirty = true return end
    local page = math.max(1, ui.pageRows() - 2)
    if k == "pgup" then scroll(page) return end
    if k == "pgdn" then scroll(-page) return end
    if e.ctrl and k == "end" then scroll(-100000) return end
    if e.ctrl and k == "home" then scroll(100000) return end
  end
  local r, text = input.key(e)
  if r == "submit" then
    local w = model.active
    if w then w.scroll = 0 end
    cmds.run(text)
  end
  if r then model.dirty = true end
end

local function start()
  local target = args[1]
  if target then
    local host, port = target:match("^(.-):%+?(%d+)$")
    host = host or target
    port = tonumber(port) or 6697
    local cfg = {name = host:match("^irc%.([^.]+)%.") or host:match("^([^.]+)") or host,
                 host = host, port = port, tls = port ~= 6667 and port ~= 6668, autojoin = {}}
    for i = 2, #args do cfg.autojoin[#cfg.autojoin + 1] = args[i] end
    cmds.connect(cfg)
    return
  end
  local any = false
  for _, s in ipairs(data.servers) do
    if s.autoconnect then
      cmds.connect(s)
      any = true
    end
  end
  if not any then
    model.open(nil, "status", "irc")
    model.add(model.active, {kind = "event", text = "Termina IRC - no server to connect to in " .. config.PATH})
    cmds.run("/help")
  else
    model.select(model.windows[1])
  end
end

local function main()
  term.cls()
  start()
  model.add(model.windows[1], {kind = "event", text = "Type /help for the commands and keys"})
  ui.draw()
  while not cmds.quit do
    local busy = false
    for _, c in ipairs(model.conns) do
      if c:pump() then busy = true end
    end
    for e in key.poll do
      onKey(e)
      busy = true
      if cmds.quit then break end
    end
    if model.dirty then ui.draw() end
    if busy then sys.yield() else sys.sleep(20) end
  end
end

local ok, e = pcall(main)
for _, c in ipairs(model.conns) do
  if c.sock then pcall(c.quit, c, "Termina 80") end
end
term.cls()
term.showcursor(true)
if not ok then error(e, 0) end
