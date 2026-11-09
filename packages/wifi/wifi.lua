-- wifi: a network manager for the Wi-Fi of Termina, which the wifi command
-- runs. Shows the connection and the networks around, and joins one
-- without restarting; if it does not work, the network of before comes back
-- by itself.
-- Keys: Up/Down select, Enter join, R scan again, Q or Esc quit.
local term, key, sys = termina.term, termina.key, termina.sys
local wifi = termina.wifi
if not wifi then
  print("This wifi needs TERMINA 6.2.0 or later (termina.wifi).")
  return
end

local COLS, ROWS = term.cols(), term.rows()
local HEAD = 1 * 16 + 15          -- header and footer: white on blue
local TEXT, DIM, BRIGHT = 0x07, 0x08, 0x0F
local SEL = 0x1F
local GREEN, YELLOW, RED = 0x0A, 0x0E, 0x0C
local SPIN = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
local EIGHTHS = {"", "▏", "▎", "▍", "▌", "▋", "▊", "▉"}

local status = wifi.status()
local nets = {}                  -- the last scan
local scanning = false
local sel, top = 1, 1
local message, messageAttr = nil, TEXT
local frame = 0

-- ------------------------------------------------------------------ helpers

local function len(s) return utf8.len(s) or #s end

-- s cut or padded to exactly w cells
local function fit(s, w)
  local n = len(s)
  if n > w then return s:sub(1, (utf8.offset(s, w) or #s + 1) - 1) .. "…" end
  return s .. string.rep(" ", w - n)
end

local function put(x, y, s, attr) return term.put(x, y, s, attr or TEXT) end

-- 0 to 3 bars, as the status bar shows them
local function bars(rssi)
  return rssi >= -60 and 3 or rssi >= -70 and 2 or rssi >= -80 and 1 or 0
end

local BAR_COLORS = {[0] = DIM, RED, YELLOW, GREEN}

local function icon(rssi) return utf8.char(0xF8F0 + bars(rssi)) end

-- signal quality in %, from -100 dBm (0) to -50 dBm (100)
local function quality(rssi) return math.max(0, math.min(100, 2 * (rssi + 100))) end

local function gauge(pct, w)
  local e = pct * w * 8 // 100
  local full, part = e // 8, e % 8
  return string.rep("█", full) .. EIGHTHS[part + 1] .. string.rep("░", w - full - (part > 0 and 1 or 0))
end

-- A rounded frame with a title, cleared inside.
local function box(x, y, w, h, title, attr)
  attr = attr or DIM
  put(x, y, "╭" .. string.rep("─", w - 2) .. "╮", attr)
  for i = 1, h - 2 do
    put(x, y + i, "│" .. string.rep(" ", w - 2) .. "│", attr)
  end
  put(x, y + h - 1, "╰" .. string.rep("─", w - 2) .. "╯", attr)
  if title then put(x + 2, y, " " .. title .. " ", BRIGHT) end
end

-- ------------------------------------------------------------------ drawing

local LIST_Y = 10                -- first row of the list
local function listRows() return ROWS - 2 - LIST_Y end

local function header()
  term.fill(1, " ", HEAD)
  local x = put(0, 1, " \u{F8F3} NETWORK ", 0x2F)
  put(x, 1, "\u{E0B0}", 0x21)
  local right = scanning and (SPIN[frame % #SPIN + 1] .. " Scanning…") or (#nets .. " networks")
  put(COLS - 1 - len(right), 1, right, HEAD)
end

local function footer()
  term.fill(ROWS - 1, " ", HEAD)
  if message then
    put(1, ROWS - 1, message, (messageAttr & 0x0F) | 0x10)
  else
    put(1, ROWS - 1, "↑↓ Select  Enter Join  R Scan  Q Quit", HEAD)
  end
end

local function connection()
  local s = status
  box(0, 3, COLS, 6, "Connection")
  local line, attr
  if s.mode == "ap" then
    line, attr = "◉ Access point " .. s.ap .. " (password termina80)", YELLOW
  elseif s.connected then
    line, attr = "● Connected to " .. s.ssid, GREEN
  else
    line, attr = "✗ Not connected", RED
  end
  put(2, 4, line, attr)
  if s.connected then
    local q = quality(s.rssi)
    local x = put(2, 5, "Signal   ", DIM)
    x = x + put(2 + x, 5, icon(s.rssi), BAR_COLORS[bars(s.rssi)])
    put(4 + x, 5, gauge(q, 12) .. string.format(" %3d%%  %d dBm, channel %d", q, s.rssi, s.channel), TEXT)
  end
  put(2, 6, "IP       ", DIM)
  put(11, 6, s.ip or "-", TEXT)
  put(2, 7, "MAC      ", DIM)
  put(11, 7, s.mac .. (s.saved ~= "" and ("   joined at boot: " .. s.saved) or ""), TEXT)
end

local NAME_W = math.max(16, math.min(32, COLS - 40))

local function list()
  local y0 = LIST_Y - 1
  put(0, y0, fit("   Network", NAME_W + 4) .. "Signal          Ch  Security", DIM)
  for i = 0, listRows() - 1 do
    local n = nets[top + i]
    local y = LIST_Y + i
    term.fill(y, " ", TEXT)
    if n then
      local chosen = top + i == sel
      local here = status.connected and n.ssid == status.ssid
      local a = chosen and SEL or TEXT
      term.fill(y, " ", a)
      put(1, y, here and "●" or " ", chosen and SEL or GREEN)
      put(3, y, fit(n.ssid, NAME_W), a)
      local x = 4 + NAME_W
      put(x, y, icon(n.rssi), chosen and SEL or BAR_COLORS[bars(n.rssi)])
      put(x + 2, y, string.format("%3d%% %4d dBm", quality(n.rssi), n.rssi), a)
      put(x + 16, y, string.format("%2d", n.channel), a)
      put(x + 20, y, n.secure and "WPA" or "open", chosen and SEL or (n.secure and TEXT or YELLOW))
    elseif i == 0 and not scanning then
      put(3, y, "No network found: R to scan again", DIM)
    end
  end
end

local function draw()
  term.attr(TEXT)
  term.cls()
  header()
  connection()
  list()
  footer()
end

-- ------------------------------------------------------------- the actions

local function scan()
  if wifi.scan() then scanning = true end
  header()
end

local function show(msg, attr)
  message, messageAttr = msg, attr or TEXT
  footer()
end

-- A password, typed in a box in the middle; nil if Esc.
local function askPassword(ssid)
  local w = math.min(COLS - 4, 56)
  local x, y = (COLS - w) // 2, ROWS // 2 - 3
  local pw, visible = "", false
  while true do
    box(x, y, w, 6, "Join " .. ssid, BRIGHT)
    put(x + 2, y + 2, "Password ", DIM)
    local shown = visible and pw or string.rep("•", len(pw))
    put(x + 11, y + 2, fit(shown .. "_", w - 13), BRIGHT)
    put(x + 2, y + 4, "Enter join  Tab " .. (visible and "hide" or "show") .. "  Esc cancel", DIM)
    local e = key.wait()
    if e.type == "char" then
      if len(pw) < 63 then pw = pw .. e.ch end
    elseif e.type == "key" then
      if e.key == "enter" then return pw
      elseif e.key == "esc" then return nil
      elseif e.key == "tab" then visible = not visible
      elseif e.key == "backspace" and #pw > 0 then
        pw = pw:sub(1, utf8.offset(pw, -1) - 1)
      end
    end
  end
end

-- Joins a network, the progress in a box; the keyboard of the PC
-- (termina-input) follows only if the PC is on that network too.
local function join(n)
  local pw = ""
  if n.secure then
    pw = askPassword(n.ssid)
    if not pw then return draw() end
  end
  wifi.connect(n.ssid, pw)
  local w = math.min(COLS - 4, 56)
  local x, y = (COLS - w) // 2, ROWS // 2 - 3
  local t0 = sys.millis()
  local state
  repeat
    local secs = (sys.millis() - t0) // 1000
    box(x, y, w, 6, "Join " .. n.ssid, BRIGHT)
    put(x + 2, y + 2, SPIN[frame % #SPIN + 1] .. " Connecting… " .. secs .. " s", BRIGHT)
    put(x + 2, y + 3, "The PC keyboard follows if the PC is on that network.", DIM)
    frame = frame + 1
    sys.sleep(100)
    state = wifi.joined()
  until state ~= "connecting"
  status = wifi.status()
  draw()
  if state == "connected" then
    show("✓ Connected to " .. n.ssid .. (status.ip and (", IP " .. status.ip) or ""), GREEN)
  else
    show("✗ Could not join " .. n.ssid .. (n.secure and " (wrong password?)" or "") .. ": back as before", RED)
  end
end

-- ---------------------------------------------------------------- the loop

local saved = term.attr()
term.showcursor(false)
sys.saver(false)
scan()
draw()
local statusAt = sys.millis()
while true do
  local e = key.poll()
  if e then
    local k = e.type == "char" and e.ch:lower() or e.type == "key" and e.key or nil
    if message and k then
      message = nil
      footer()
    end
    if k == "q" or k == "esc" then break
    elseif k == "r" then scan()
    elseif k == "up" and sel > 1 then sel = sel - 1
    elseif k == "down" and sel < #nets then sel = sel + 1
    elseif k == "pgup" then sel = math.max(1, sel - listRows())
    elseif k == "pgdn" then sel = math.max(1, math.min(#nets, sel + listRows()))
    elseif k == "enter" and nets[sel] then join(nets[sel])
    end
    if sel < top then top = sel end
    if sel >= top + listRows() then top = sel - listRows() + 1 end
    list()
  else
    if scanning then
      local found = wifi.networks()
      if found then
        scanning, nets = false, found
        sel, top = math.min(sel, math.max(1, #nets)), 1
        list()
      end
      frame = frame + 1
      header()
    end
    if sys.millis() - statusAt >= 2000 then  -- the signal moves
      status = wifi.status()
      statusAt = sys.millis()
      connection()
    end
    sys.sleep(80)
  end
end

term.attr(saved)
term.cls()
term.showcursor(true)
