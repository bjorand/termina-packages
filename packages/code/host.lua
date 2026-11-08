-- code.host: what the editor needs from the machine, the same on Termina and
-- on any other computer with Lua 5.4, luasystem and LuaFileSystem.
--
--   term   the screen: putattr, cell, cursor, showcursor, cols, rows, cls
--   key    the keyboard and the mouse: poll() -> event or nil
--   sys    millis, sleep, yield, clipboard, setclipboard
--   fs     files, through lfs and io
--   hl     syntax highlighting (termina.hl, or the same in Lua)
--   vt     virtual terminals (termina.vt), nil elsewhere
--
-- On Termina the native libraries draw and read the keyboard (fastest on the
-- ESP32); elsewhere the screen is drawn with ANSI escape codes and the keys
-- and mouse come from luasystem as xterm sequences. Rows are counted from 0,
-- the first one the editor may use (on Termina, the one below the status bar).
local system = require "system"
local lfs = require "lfs"

local M = {}

local termina = rawget(_G, "termina")
local native = termina ~= nil and termina.term ~= nil and os.getenv("CODE_ANSI") == nil
M.termina = termina
M.native = native

-- ------------------------------------------------------------------ time

local sys = {}
M.sys = sys

if termina then
  sys.millis = termina.sys.millis
  sys.sleep = termina.sys.sleep
  sys.yield = termina.sys.yield
  sys.memlimit = termina.sys.memlimit
else
  function sys.millis() return math.floor(system.monotime() * 1000) end
  function sys.sleep(ms) system.sleep(ms / 1000) end
  function sys.yield() end
  function sys.memlimit() end
end

-- ------------------------------------------------------------------ files

local fs = {}
M.fs = fs

function fs.read(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

function fs.write(p, s)
  local f = io.open(p, "wb")
  if not f then return false end
  local ok = f:write(s)
  f:close()
  return ok ~= nil
end

function fs.exists(p) return lfs.attributes(p, "mode") ~= nil end
function fs.isdir(p) return lfs.attributes(p, "mode") == "directory" end
function fs.size(p) return lfs.attributes(p, "size") end
function fs.mtime(p) return lfs.attributes(p, "modification") or 0 end
function fs.cwd() return lfs.currentdir() end
function fs.remove(p) return os.remove(p) ~= nil end

function fs.rename(a, b)
  if fs.exists(b) then return false end
  return os.rename(a, b) ~= nil
end

-- {name, dir, size} of the entries of a directory, or nil.
function fs.dir(d)
  if not fs.isdir(d) then return nil end
  local out = {}
  for name in lfs.dir(d) do
    if name ~= "." and name ~= ".." then
      local p = (d == "/" and "" or d) .. "/" .. name
      local a = lfs.attributes(p)
      if a then out[#out + 1] = {name = name, dir = a.mode == "directory", size = a.size} end
    end
  end
  return out
end

-- Creates a directory and its parents.
function fs.mkdir(p)
  if fs.isdir(p) then return true end
  local parent = p:match("^(.+)/[^/]+$")
  if parent and not fs.isdir(parent) then fs.mkdir(parent) end
  return lfs.mkdir(p) == true
end

-- Removes a directory and everything it holds.
function fs.rmtree(p)
  for _, e in ipairs(fs.dir(p) or {}) do
    local c = p .. "/" .. e.name
    if e.dir then fs.rmtree(c) else os.remove(c) end
  end
  return lfs.rmdir(p) == true
end

-- ------------------------------------------------------------------ highlighting

M.hl = termina and termina.hl or require "code.hl"

-- termina.vt draws on Termina's screen, where row 0 is the status bar: a vt
-- of the editor draws one row lower. Without the native screen, none (the
-- panel then runs commands with code.pipevt).
if native and termina.vt then
  M.vt = {
    open = function(cols, rows)
      local v = termina.vt.open(cols, rows)
      return setmetatable({
        draw = function(_, x, y, ...) return v:draw(x, y + 1, ...) end,
      }, {
        __index = function(_, name)
          local f = v[name]
          return function(_, ...) return f(v, ...) end
        end,
      })
    end,
  }
end

-- ------------------------------------------------------------------ clipboard

local clip = ""        -- when there is no system clipboard to reach
local copyCmd, pasteCmd

local function findClipboard()
  if copyCmd ~= nil then return end
  copyCmd, pasteCmd = false, false
  local h = io.popen("uname 2>/dev/null")
  local os_ = h and h:read("l") or ""
  if h then h:close() end
  local function has(cmd)
    local ok = os.execute("command -v " .. cmd .. " >/dev/null 2>&1")
    return ok == true or ok == 0
  end
  if os_ == "Darwin" then
    copyCmd, pasteCmd = "pbcopy", "pbpaste"
  elseif has("wl-copy") then
    copyCmd, pasteCmd = "wl-copy", "wl-paste -n"
  elseif has("xclip") then
    copyCmd, pasteCmd = "xclip -selection clipboard", "xclip -selection clipboard -o"
  end
end

local function base64(s)
  local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  return ((s:gsub(".", function(c)
    local r, n = "", c:byte()
    for i = 8, 1, -1 do r = r .. (n % 2 ^ i - n % 2 ^ (i - 1) > 0 and "1" or "0") end
    return r
  end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
    if #x < 6 then return "" end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
    return b:sub(c + 1, c + 1)
  end) .. ({"", "==", "="})[#s % 3 + 1])
end

if termina then
  sys.clipboard = termina.sys.clipboard
  sys.setclipboard = termina.sys.setclipboard
else
  function sys.setclipboard(t)
    clip = t
    findClipboard()
    if copyCmd then
      local h = io.popen(copyCmd, "w")
      if h then
        h:write(t)
        h:close()
        return
      end
    end
    io.write("\27]52;c;" .. base64(t) .. "\7")  -- OSC 52: the terminal's clipboard
  end

  function sys.clipboard()
    findClipboard()
    if pasteCmd then
      local h = io.popen(pasteCmd)
      if h then
        local t = h:read("a") or ""
        h:close()
        return t
      end
    end
    return clip
  end
end

-- ------------------------------------------------------------------ screen

local term, key = {}, {}
M.term, M.key = term, key

if native then
  -- Termina: its own text screen, row 0 being the status bar.
  local tt, tk = termina.term, termina.key
  function term.cols() return tt.cols() end
  function term.rows() return tt.rows() - 1 end
  function term.putattr(x, y, s, a, w, pad) return tt.putattr(x, y + 1, s, a, w, pad) end
  function term.cell(x, y, ch, a) return tt.cell(x, y + 1, ch, a) end
  function term.cursor(x, y)
    if x then
      tt.cursor(x, y + 1)
      return x, y
    end
    local cx, cy = tt.cursor()
    return cx, cy - 1
  end
  term.showcursor = tt.showcursor
  term.attr = tt.attr
  term.cls = tt.cls
  function term.flush() end
  function term.invalidate() end

  function key.poll()
    local e = tk.poll()
    if e and e.y then e.y = e.y - 1 end
    return e
  end
else
  -- ANSI: what is on the terminal (shown) and what the editor drew since
  -- (cells), sent as differences by flush().
  local W, H = 80, 24
  local ch, at, sch, sat = {}, {}, {}, {}
  local cx, cy, show = 0, 0, false
  local shownCursor  -- "x,y,show" last sent
  local out = {}

  local function size()
    local r, c = system.termsize()
    return c or 80, r or 24
  end

  local function reset()
    W, H = size()
    for i = 1, W * H do
      ch[i], at[i], sch[i], sat[i] = " ", 7, nil, nil
    end
    for i = W * H + 1, #ch do ch[i], at[i], sch[i], sat[i] = nil, nil, nil, nil end
    shownCursor = nil
  end
  reset()

  function term.cols() return W end
  function term.rows() return H end

  -- Whether the terminal changed size since the last call (then everything
  -- is drawn again).
  function term.resized()
    local w, h = size()
    if w == W and h == H then return false end
    reset()
    io.write("\27[2J")
    return true
  end

  function term.invalidate()
    for i = 1, W * H do sch[i] = nil end
    shownCursor = nil
    io.write("\27[2J")
  end

  function term.putattr(x, y, s, a, w, pad)
    if y < 0 or y >= H then return 0 end
    local na = #a
    local last = na > 0 and a:byte(1) or 7
    local col = 0
    local base = y * W + x + 1
    for p, c in utf8.codes(s, true) do
      if w and col >= w then break end
      if p <= na then last = a:byte(p) end
      if x + col >= 0 and x + col < W then
        ch[base + col], at[base + col] = c < 32 and "?" or utf8.char(c), last
      end
      col = col + 1
    end
    if w then
      local pa = pad or last
      while col < w do
        if x + col >= 0 and x + col < W then ch[base + col], at[base + col] = " ", pa end
        col = col + 1
      end
    end
    return col
  end

  function term.cell(x, y, c, a)
    if x < 0 or y < 0 or x >= W or y >= H then return end
    if type(c) == "number" then c = c < 128 and string.char(c) or "?" end
    local i = y * W + x + 1
    ch[i], at[i] = c, a or 7
  end

  function term.cursor(x, y)
    if x then cx, cy = x, y end
    return cx, cy
  end

  function term.showcursor(b) show = b and true or false end
  function term.attr() return 7 end

  function term.cls()
    for i = 1, W * H do ch[i], at[i] = " ", 7 end
  end

  -- CGA color order (that of the attributes) -> ANSI color order.
  local ANSI = {[0] = 0, 4, 2, 6, 1, 5, 3, 7}
  local function sgr(a)
    local fg, bg = a & 15, (a >> 4) & 15
    return string.format("\27[0;%d;%dm", (fg > 7 and 90 or 30) + ANSI[fg & 7], (bg > 7 and 100 or 40) + ANSI[bg & 7])
  end

  -- Sends what changed since the last call.
  function term.flush()
    local n = 0
    local lastAttr, atX, atY
    for y = 0, H - 1 do
      local row = y * W
      for x = 0, W - 1 do
        local i = row + x + 1
        local c, a = ch[i], at[i]
        if c ~= sch[i] or a ~= sat[i] then
          if atY ~= y or atX ~= x then
            n = n + 1
            out[n] = "\27[" .. (y + 1) .. ";" .. (x + 1) .. "H"
          end
          if a ~= lastAttr then
            n = n + 1
            out[n] = sgr(a)
            lastAttr = a
          end
          n = n + 1
          out[n] = c
          sch[i], sat[i] = c, a
          atX, atY = x + 1, y
        end
      end
    end
    local cur = cx .. "," .. cy .. "," .. tostring(show)
    if n > 0 or cur ~= shownCursor then
      n = n + 1
      out[n] = "\27[" .. (cy + 1) .. ";" .. (cx + 1) .. "H" .. (show and "\27[?25h" or "\27[?25l")
      shownCursor = cur
    end
    if n > 0 then
      io.write(table.concat(out, "", 1, n))
      io.flush()
    end
  end

  -- ---------------------------------------------------------------- keys

  local TILDE = {
    [1] = "home", [2] = "insert", [3] = "delete", [4] = "end", [5] = "pgup", [6] = "pgdn",
    [7] = "home", [8] = "end", [11] = "f1", [12] = "f2", [13] = "f3", [14] = "f4", [15] = "f5",
    [17] = "f6", [18] = "f7", [19] = "f8", [20] = "f9", [21] = "f10", [23] = "f11", [24] = "f12",
  }
  local FINAL = {
    A = "up", B = "down", C = "right", D = "left", H = "home", F = "end",
    P = "f1", Q = "f2", R = "f3", S = "f4",
  }
  local held = 0  -- mouse buttons down: 1 left, 2 right, 4 middle

  local function keyEvent(name, m)
    m = (m or 1) - 1
    return {type = "key", key = name, shift = m & 1 ~= 0, alt = m & 2 ~= 0, ctrl = m & 4 ~= 0}
  end

  -- One byte below 32 (or 127): Enter, Tab, Backspace, Esc, Ctrl+letter.
  local function control(b, alt)
    local e
    if b == 13 then e = keyEvent("enter")
    elseif b == 9 then e = keyEvent("tab")
    elseif b == 127 then e = keyEvent("backspace")
    elseif b == 27 then e = keyEvent("esc")
    elseif b == 0 then e = keyEvent(" ", 5)
    elseif b >= 1 and b <= 26 then e = keyEvent(string.char(96 + b), 5)
    elseif b == 31 then e = keyEvent("/", 5)  -- Ctrl+/ sends Ctrl+_
    elseif b >= 28 then e = keyEvent(string.char(64 + b):lower(), 5)
    else return nil end
    e.alt = e.alt or alt
    return e
  end

  local function mouse(b, x, y, final)
    local e = {x = x - 1, y = y - 1, shift = b & 4 ~= 0, alt = b & 8 ~= 0, ctrl = b & 16 ~= 0}
    if b & 64 ~= 0 then
      e.type, e.n = "wheel", (b & 1) == 0 and 1 or -1
      return e
    end
    if b & 32 ~= 0 then
      if held == 0 then return nil end
      e.type, e.buttons = "move", held
      return e
    end
    local btn = ({[0] = 0, 2, 1})[b & 3]  -- xterm: left, middle, right
    if not btn then return nil end
    local bit = ({[0] = 1, 2, 4})[btn]
    e.type, e.button, e.down = "mouse", btn, final == "M"
    if e.down then held = held | bit else held = held & ~bit end
    return e
  end

  local function decode(s)
    if #s == 1 then
      local b = s:byte()
      if b < 32 or b == 127 then return control(b) end
      return {type = "char", ch = s}
    end
    if s:byte() ~= 27 then return {type = "char", ch = s} end  -- UTF-8 character
    local mb, mx, my, mf = s:match("^\27%[<(%d+);(%d+);(%d+)([Mm])$")
    if mb then return mouse(tonumber(mb), tonumber(mx), tonumber(my), mf) end
    local params, final = s:match("^\27%[([%d;]*)([%a~])$")
    if not final then params, final = s:match("^\27O([%d;]*)(%a)$") end
    if final then
      local n, m = params:match("^(%d*);?(%d*)$")
      n, m = tonumber(n), tonumber(m)
      if final == "~" then
        if n == 200 then return {type = "pastestart"} end
        return TILDE[n] and keyEvent(TILDE[n], m) or nil
      end
      if final == "Z" then return keyEvent("tab", 2) end
      if FINAL[final] then return keyEvent(FINAL[final], m or (n and n > 1 and n) or 1) end
      return nil
    end
    -- Alt+key: Esc, then the key
    local rest = s:sub(2)
    if #rest == 1 and (rest:byte() < 32 or rest:byte() == 127) then return control(rest:byte(), true) end
    if utf8.len(rest) == 1 then
      local e = keyEvent(rest:lower(), 3)
      e.shift = rest:lower() ~= rest
      return e
    end
    return nil
  end

  -- Bracketed paste: the text between ESC[200~ and ESC[201~ comes as one
  -- {type = "paste", text} event, not as typed keys.
  local function readPaste()
    local parts = {}
    local t0 = system.monotime()
    while system.monotime() - t0 < 5 do
      local s = system.readansi(0.2)
      if s == "\27[201~" then break end
      if s then parts[#parts + 1] = s == "\r" and "\n" or s end
    end
    return {type = "paste", text = table.concat(parts)}
  end

  function key.poll()
    term.flush()
    while true do
      local s = system.readansi(0)
      if not s then return nil end
      local e = decode(s)
      if e and e.type == "pastestart" then return readPaste() end
      if e then return e end
    end
  end
end

-- ------------------------------------------------------------------ start and stop

local saved  -- terminal settings before start()

-- Takes the terminal: raw keys (Ctrl+C, Ctrl+S, Ctrl+Z are keys), mouse,
-- alternate screen.
function M.start()
  saved = system.termbackup()
  local t = system.tcgetattr(io.stdin)
  if t then
    if native then
      system.tcsetattr(io.stdin, system.TCSANOW, {lflag = t.lflag - system.L_ISIG})
    else
      system.tcsetattr(io.stdin, system.TCSANOW, {
        iflag = t.iflag - system.I_ICRNL - system.I_IXON,
        lflag = t.lflag - system.L_ICANON - system.L_ECHO - system.L_ISIG - system.L_IEXTEN,
      })
      system.setnonblock(io.stdin, true)
    end
  end
  if not native then
    io.write("\27[?1049h\27[?1002h\27[?1006h\27[?2004h\27[?25l\27[2J")
    term.invalidate()
  end
end

-- Gives the terminal back as it was.
function M.stop()
  if not native then
    io.write("\27[0m\27[?2004l\27[?1006l\27[?1002l\27[?25h\27[?1049l")
    io.flush()
  end
  if saved then system.termrestore(saved) end
  saved = nil
end

-- Runs a command on the whole screen, then waits for a key.
function M.fullscreen(cmd)
  M.stop()
  if native then
    termina.term.attr(0x07)
    termina.term.cls()
    termina.term.showcursor(true)
  end
  os.execute(cmd)
  io.write("\n\27[90m[" .. cmd .. ": done, press a key]\27[0m")
  io.flush()
  M.start()
  while not key.poll() do sys.sleep(20) end
  if native then termina.term.cls() else term.invalidate() end
end

return M
