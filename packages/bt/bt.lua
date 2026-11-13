-- bt: the Bluetooth manager (TERMINA 8.16.0 and later): keyboards and mice
-- that speak Bluetooth LE, such as a phone acting as a keyboard and touchpad.
--   bt                  shows the paired devices and the ones around, pairs
--                       (keys: Up/Down select, Enter pair or connect,
--                       F forget, B on/off, K keymap, R scan, Q or Esc quit)
--   bt status           Bluetooth, the keymap and the paired devices, as text
--   bt on | off         turns Bluetooth on or off (saved for the next boots)
--   bt scan             lists the keyboards and mice around
--   bt pair <addr>      pairs with one of them (or reconnects a paired one)
--   bt forget <addr>    forgets a paired device
-- Paired devices reconnect by themselves whenever they show up. The keymap
-- (also the keymap command) turns the keys of the keyboards into characters.
local term, key, sys = termina.term, termina.key, termina.sys
local bt = termina.bt
if not bt then
  print("This bt needs TERMINA 8.16.0 or later (termina.bt).")
  return
end

local status = bt.status()
if not status.available then
  print("No Bluetooth on this machine.")
  return
end

-- ------------------------------------------------------- the command line

local function describe(d)
  local s = d.addr .. "  " .. d.name .. " (" .. d.kind .. ")"
  if d.connected then s = s .. ", connected" end
  if d.battery then s = s .. ", battery " .. d.battery .. "%" end
  if d.rssi then s = s .. ", " .. d.rssi .. " dBm" end
  if d.paired and d.rssi then s = s .. ", paired" end
  return s
end

local function printStatus()
  local s = bt.status()
  print("Bluetooth " .. (s.enabled and "on" or "off") .. ", keymap " .. s.keymap)
  local devs = bt.devices()
  if #devs == 0 then print("No paired device.") end
  for _, d in ipairs(devs) do print("  " .. describe(d)) end
end

-- Waits for a pairing to end; true if the device is connected.
local function waitPairing(tick)
  local state, why
  repeat
    sys.sleep(100)
    if tick then tick() end
    state, why = bt.pairing()
  until state ~= "connecting" and state ~= "pairing"
  return state == "connected", why
end

local function scanNow(tick)
  if not bt.scan() then return nil end
  local found
  repeat
    sys.sleep(100)
    if tick then tick() end
    found = bt.found()
  until found
  return found
end

local cmd = arg[1]
if cmd == "status" then
  printStatus()
  return
elseif cmd == "on" or cmd == "off" then
  bt.enable(cmd == "on")
  print("Bluetooth " .. cmd .. ".")
  return
elseif cmd == "scan" then
  if not status.enabled then print("Bluetooth is off: bt on") os.exit(1) end
  termina.write("Scanning")
  local n = 0
  local found = scanNow(function()
    n = n + 1
    if n % 10 == 0 then termina.write(".") end
  end)
  print()
  if not found or #found == 0 then print("No keyboard or mouse around (is it waiting to pair?).") end
  for _, d in ipairs(found or {}) do print("  " .. describe(d)) end
  return
elseif cmd == "pair" and arg[2] then
  if not status.enabled then print("Bluetooth is off: bt on") os.exit(1) end
  -- a device not paired yet must have been seen by a scan
  local known = false
  for _, d in ipairs(bt.devices()) do known = known or d.addr == arg[2] end
  if not known then scanNow() end
  print("Pairing " .. arg[2] .. ": accept the request on the device if it asks.")
  bt.pair(arg[2])
  local shown
  local ok, why = waitPairing(function()
    local _, code, compare = bt.pairing()
    if code and code ~= shown then
      shown = code
      print("Code " .. code .. (compare and ": confirm on the device that it shows the same."
        or ": if the device asks for it, type it there (a keyboard: then Enter)."))
    end
  end)
  if ok then
    printStatus()
  else
    print("Could not pair: " .. (why or "?"))
    os.exit(1)
  end
  return
elseif cmd == "forget" and arg[2] then
  if bt.forget(arg[2]) then
    print("Forgot " .. arg[2] .. ".")
  else
    print(arg[2] .. " is not paired.")
    os.exit(1)
  end
  return
elseif cmd then
  print("Usage: bt [status | on | off | scan | pair <addr> | forget <addr>]")
  os.exit(1)
end

-- ------------------------------------------------------- the manager

local COLS, ROWS = term.cols(), term.rows()
local HEAD = 1 * 16 + 15          -- header and footer: white on blue
local TEXT, DIM, BRIGHT = 0x07, 0x08, 0x0F
local SEL = 0x1F
local GREEN, YELLOW, RED, BLUE = 0x0A, 0x0E, 0x0C, 0x09
local SPIN = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
local RUNE = "\u{F8F4}"

local devices = {}               -- paired
local nearby = {}                -- the last scan, not paired
local items = {}                 -- what the list shows: {dev, paired}
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

-- 0 to 3 bars from the signal, as the Wi-Fi shows it
local function bars(rssi)
  return rssi >= -60 and 3 or rssi >= -70 and 2 or rssi >= -80 and 1 or 0
end
local BAR_COLORS = {[0] = DIM, RED, YELLOW, GREEN}

-- The list: the paired devices, then the others around.
local function rebuild()
  devices = bt.devices()
  local paired = {}
  for _, d in ipairs(devices) do paired[d.addr] = true end
  items = {}
  for _, d in ipairs(devices) do items[#items + 1] = {dev = d, paired = true} end
  for _, d in ipairs(nearby) do
    if not paired[d.addr] then items[#items + 1] = {dev = d} end
  end
  -- the signal of a paired device seen by the scan
  for _, d in ipairs(nearby) do
    for _, it in ipairs(items) do
      if it.paired and it.dev.addr == d.addr then it.dev.rssi = d.rssi end
    end
  end
  sel = math.max(1, math.min(sel, #items))
end

-- ------------------------------------------------------------------ drawing

local LIST_Y = 9                 -- first row of the list
local function listRows() return ROWS - 2 - LIST_Y end

local function header()
  term.fill(1, " ", HEAD)
  local x = put(0, 1, " " .. RUNE .. " BLUETOOTH ", 0x3F)
  put(x, 1, "\u{E0B0}", 0x31)
  local right
  if not status.enabled then right = "off"
  elseif scanning then right = SPIN[frame % #SPIN + 1] .. " Scanning…"
  else right = status.connected .. " connected" end
  put(COLS - 1 - len(right), 1, right, HEAD)
end

local function footer()
  term.fill(ROWS - 1, " ", HEAD)
  if message then
    put(1, ROWS - 1, message, (messageAttr & 0x0F) | 0x10)
  elseif status.enabled then
    put(1, ROWS - 1, "↑↓ Select  Enter Pair/connect  F Forget  R Scan  K Keymap  B Off  Q Quit", HEAD)
  else
    put(1, ROWS - 1, "B Turn on  K Keymap  Q Quit", HEAD)
  end
end

local function adapter()
  box(0, 3, COLS, 5, "Bluetooth")
  if status.enabled then
    put(2, 4, "● On", GREEN)
    put(8, 4, "paired devices reconnect when they show up", DIM)
  else
    put(2, 4, "✗ Off", RED)
    put(9, 4, "B turns it on (saved for the next boots)", DIM)
  end
  local _, names = bt.keymap()
  local x = put(2, 5, "Keymap   ", DIM)
  x = 2 + x + put(2 + x, 5, status.keymap, BRIGHT)
  put(x + 1, 5, "(" .. table.concat(names, ", ") .. ": K changes it, for the keyboards only)", DIM)
end

local NAME_W = math.max(16, math.min(30, COLS - 50))

local function list()
  local y0 = LIST_Y - 1
  put(0, y0, fit("   Device", NAME_W + 4) .. fit("Kind", 16) .. fit("Signal", 10) .. "State", DIM)
  for i = 0, listRows() - 1 do
    local it = items[top + i]
    local y = LIST_Y + i
    term.fill(y, " ", TEXT)
    if it then
      local d = it.dev
      local chosen = top + i == sel
      local a = chosen and SEL or TEXT
      term.fill(y, " ", a)
      put(1, y, d.connected and "●" or it.paired and "○" or " ", chosen and SEL or (d.connected and BLUE or DIM))
      put(3, y, fit(d.name ~= "" and d.name or d.addr, NAME_W), a)
      local x = 4 + NAME_W
      put(x, y, fit(d.kind, 16), a)
      if d.rssi then
        put(x + 16, y, utf8.char(0xF8F0 + bars(d.rssi)), chosen and SEL or BAR_COLORS[bars(d.rssi)])
        put(x + 18, y, string.format("%d", d.rssi), a)
      end
      local state = d.connected and ("connected" .. (d.battery and (", " .. d.battery .. "%") or ""))
        or it.paired and "paired" or "Enter pairs"
      put(x + 26, y, state, chosen and SEL or (d.connected and GREEN or it.paired and TEXT or DIM))
    elseif i == 0 then
      if not status.enabled then
        put(3, y, "Bluetooth is off.", DIM)
      elseif not scanning then
        put(3, y, "No device: put the keyboard or mouse in pairing mode, then R to scan", DIM)
      end
    end
  end
end

local function draw()
  term.attr(TEXT)
  term.cls()
  header()
  adapter()
  list()
  footer()
end

-- ------------------------------------------------------------- the actions

local function show(msg, attr)
  message, messageAttr = msg, attr or TEXT
  footer()
end

local function scan()
  if bt.scan() then scanning = true end
  header()
end

local function pair(it)
  local d = it.dev
  bt.pair(d.addr)
  local w = math.min(COLS - 4, 64)
  local x, y = (COLS - w) // 2, ROWS // 2 - 3
  local t0 = sys.millis()
  local ok, why = waitPairing(function()
    local secs = (sys.millis() - t0) // 1000
    local state, code, compare = bt.pairing()
    box(x, y, w, 7, (it.paired and "Connect " or "Pair ") .. (d.name ~= "" and d.name or d.addr), BRIGHT)
    put(x + 2, y + 2, SPIN[frame % #SPIN + 1] .. (state == "pairing" and " Pairing… " or " Connecting… ") .. secs .. " s", BRIGHT)
    if code then
      put(x + 2, y + 3, "Code ", DIM)
      put(x + 7, y + 3, code, YELLOW)
      put(x + 2, y + 4, compare and "Confirm on the device that it shows the same code."
        or "If the device asks for it, type it there (a keyboard: then Enter).", DIM)
    else
      put(x + 2, y + 3, "Accept the request on the device if it asks.", DIM)
    end
    frame = frame + 1
  end)
  status = bt.status()
  rebuild()
  draw()
  if ok then
    show("✓ " .. (d.name ~= "" and d.name or d.addr) .. " connected: its keys and pointer are Termina's", GREEN)
  else
    show("✗ " .. (why or "failed"), RED)
  end
end

local function forget(it)
  if not it.paired then return end
  bt.forget(it.dev.addr)
  rebuild()
  draw()
  show("Forgot " .. (it.dev.name ~= "" and it.dev.name or it.dev.addr) .. " (forget Termina on the device too)", YELLOW)
end

local function nextKeymap()
  local current, names = bt.keymap()
  for i, n in ipairs(names) do
    if n == current then
      bt.keymap(names[i % #names + 1])
      break
    end
  end
  status = bt.status()
  adapter()
  show("Keymap " .. status.keymap .. " (saved in /etc/termina.conf)", TEXT)
end

local function toggle()
  bt.enable(not status.enabled)
  sys.sleep(300)
  status = bt.status()
  nearby, scanning = {}, false
  if status.enabled then scan() end
  rebuild()
  draw()
end

-- ---------------------------------------------------------------- the loop

local saved = term.attr()
term.showcursor(false)
sys.saver(false)
rebuild()
if status.enabled then scan() end
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
    elseif k == "b" then toggle()
    elseif k == "k" then nextKeymap()
    elseif k == "r" and status.enabled then scan()
    elseif k == "up" and sel > 1 then sel = sel - 1
    elseif k == "down" and sel < #items then sel = sel + 1
    elseif k == "pgup" then sel = math.max(1, sel - listRows())
    elseif k == "pgdn" then sel = math.max(1, math.min(#items, sel + listRows()))
    elseif k == "enter" and items[sel] and status.enabled then pair(items[sel])
    elseif (k == "f" or k == "delete") and items[sel] then forget(items[sel])
    end
    if sel < top then top = sel end
    if sel >= top + listRows() then top = sel - listRows() + 1 end
    list()
  else
    if scanning then
      local found = bt.found()
      if found then
        scanning, nearby = false, found
        rebuild()
        list()
      end
      frame = frame + 1
      header()
    end
    if sys.millis() - statusAt >= 2000 then  -- devices come and go
      status = bt.status()
      statusAt = sys.millis()
      rebuild()
      header()
      list()
    end
    sys.sleep(80)
  end
end

term.attr(saved)
term.cls()
term.showcursor(true)
