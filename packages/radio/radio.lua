-- radio: Termina FM, an endless lofi radio composed on the fly by a server
-- (termina-radio, in the termina repository) and played by the sound card's
-- 4-voice synthesizer. The server sends notes, not audio: every Termina tuned
-- in plays the same song at the same time.
--
--   radio [host[:port]]      full screen; the host is remembered
--   radio -q [host[:port]]   no screen, for the background: radio -q &
--
-- Keys: + and - set the volume, M mutes, Esc or Q quits.
--
-- The SIGNAL panel tells why the music cuts out: the buffer is how far ahead
-- of the music the notes received go (the server sends them a few seconds
-- early; at 0 the notes come too late and are skipped), "late" counts the
-- skipped notes, "silence" the longest wait for data from the server, "loop"
-- the longest pass of this program's loop.
if not termina or not termina.synth or not termina.net then
  print("radio needs TERMINA 8.5.0 or later")
  return
end
local term, key, sys, store, synth, net = termina.term, termina.key, termina.sys,
  termina.store, termina.synth, termina.net

local DEFAULT_HOST = "radio.vendetta84.com"
local DEFAULT_PORT = 8484
local DELAY = 150          -- ms of safety after the server's air time
local LATE = 250           -- a note this late is skipped
local RETRY_MS = 5000
local NO_DATA_MS = 10000   -- NOW comes every second: this long without data, reconnect
local WINDOW_MS = 10000    -- the minimum / maximum stats cover this long

local args = {...}
if #args == 0 and arg then args = {table.unpack(arg)} end -- run/lua give them in arg
local quiet = false
local target
for _, a in ipairs(args) do
  if a == "-q" then quiet = true
  elseif a == "-h" or a == "--help" then
    print("usage: radio [-q] [host[:port]]")
    print("  -q  no screen: play in the background (radio -q &)")
    return
  else target = a end
end
if target then store.set("radio_host", target) end
target = target or store.get("radio_host") or DEFAULT_HOST
local host, port = target:match("^(.-):(%d+)$")
host = host or target
port = tonumber(port) or DEFAULT_PORT

local card = synth.present()
local VOICES = synth.VOICES or 4
local WAVES = {pulse = true, triangle = true, saw = true, noise = true}

-- ------------------------------------------------------------- state

local station = "Termina FM"
local track = nil          -- {title, key, bpm, t}
local listeners = 0
local status = "Tuning in to " .. host .. "..."
local offset = nil         -- local ms - air ms
local syncMin, syncStart = nil, 0
local queue, qhead, qtail = {}, 1, 0 -- events not played yet: queue[qhead..qtail]
local lastT = nil          -- air time of the last event received
local vol = {}             -- the volume each voice was last set to
local meter = {}           -- [v] = {start, ms, vol, label}
local master = tonumber(store.get("radio_volume")) or 12
local muted = false

-- Signal stats. *Now are being measured over the current window; the others
-- are the last full window's, shown on screen.
local st = {
  late = 0, played = 0, reconnects = 0,
  bufMin = nil, bufMinNow = nil,
  gapMax = 0, gapMaxNow = 0,
  loopMax = 0, loopMaxNow = 0,
  jitter = 0, jitterNow = 0,
  windowStart = 0,
}

local function airNow()
  return offset and sys.millis() - offset - DELAY or nil
end

local function setMaster()
  if card then synth.master(muted and 0 or master) end
end

-- Buffer: ms of music received ahead of what plays now.
local function buffered()
  local now = airNow()
  if not now or not lastT then return 0 end
  return math.max(0, lastT - now)
end

local function rollStats(ms)
  if ms - st.windowStart < WINDOW_MS then return end
  st.windowStart = ms
  st.bufMin, st.bufMinNow = st.bufMinNow, nil
  st.gapMax, st.gapMaxNow = st.gapMaxNow, 0
  st.loopMax, st.loopMaxNow = st.loopMaxNow, 0
  st.jitter, st.jitterNow = st.jitterNow, 0
end

-- ------------------------------------------------------------ protocol

local NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

local function noteName(hz)
  local n = math.floor(69 + 12 * math.log(hz / 440, 2) + 0.5)
  return NAMES[n % 12 + 1] .. (n // 12 - 1)
end

local function drumName(hz, ms)
  if ms <= 3 then return "crackle"
  elseif hz < 1000 then return "kick"
  elseif hz < 5000 then return "snare"
  else return "hat" end
end

-- NOW lines tell the air time. The smallest local - air seen is the one with
-- the least network delay: keep that, and every minute adopt the window's
-- smallest if the clocks drifted apart.
local function onNow(t)
  local now = sys.millis()
  local o = now - t
  if not offset or o < offset then offset = o end
  st.jitterNow = math.max(st.jitterNow, o - offset)
  if not syncMin or o < syncMin then syncMin = o end
  if now - syncStart > 60000 then
    if math.abs(syncMin - offset) > 30 then offset = syncMin end
    syncMin, syncStart = nil, now
  end
end

local function push(e)
  if not e.t then return end
  qtail = qtail + 1
  queue[qtail] = e
  if not lastT or e.t > lastT then lastT = e.t end
end

local function parse(line)
  local w = {}
  for f in line:gmatch("%S+") do w[#w + 1] = f end
  local k = w[1]
  if k == "N" then
    push({kind = "N", t = tonumber(w[2]), v = tonumber(w[3]),
      hz = tonumber(w[4]), ms = tonumber(w[5]), vol = tonumber(w[6])})
  elseif k == "PATCH" then
    push({kind = "PATCH", t = tonumber(w[2]), v = tonumber(w[3]), patch = {
      wave = w[4], duty = tonumber(w[5]), vol = tonumber(w[6]), attack = tonumber(w[7]),
      decay = tonumber(w[8]), sustain = tonumber(w[9]), release = tonumber(w[10])}})
  elseif k == "TRACK" then
    push({kind = "TRACK", t = tonumber(w[2]), bpm = tonumber(w[3]), key = w[4],
      title = line:match("^TRACK %S+ %S+ %S+ (.*)$") or ""})
  elseif k == "NOW" then
    onNow(tonumber(w[2]))
  elseif k == "L" then
    listeners = tonumber(w[2]) or listeners
  elseif k == "TRADIO" then
    if w[2] ~= "1" then status = "Unknown protocol version " .. tostring(w[2]) .. ": update radio" end
    station = line:match("^TRADIO %S+ (.*)$") or station
  end
end

local function play(e, now)
  if e.kind == "TRACK" then
    track = {title = e.title, key = e.key, bpm = e.bpm, t = e.t}
    if quiet then print(string.format("%s: %s (%s, %d bpm)", station, e.title, e.key, e.bpm)) end
  elseif e.kind == "PATCH" then
    if e.v >= 1 and e.v <= VOICES and WAVES[e.patch.wave] then
      vol[e.v] = e.patch.vol
      if card then synth.voice(e.v, e.patch) end
    end
  elseif e.kind == "N" then
    if e.v < 1 or e.v > VOICES or not e.hz then return end
    if now - e.t > LATE then
      st.late = st.late + 1
      return
    end
    if e.vol and e.vol ~= vol[e.v] then
      vol[e.v] = e.vol
      if card then synth.voice(e.v, {vol = e.vol}) end
    end
    if card then synth.note(e.v, e.hz, e.ms) end
    st.played = st.played + 1
    meter[e.v] = {start = sys.millis(), ms = e.ms, vol = e.vol or vol[e.v] or 15,
      label = e.v == 4 and drumName(e.hz, e.ms) or noteName(e.hz)}
  end
end

-- Plays what is due. Patches and track changes are never skipped, even late.
local function playDue()
  local now = airNow()
  if not now then return end
  while qhead <= qtail and queue[qhead].t <= now do
    play(queue[qhead], now)
    queue[qhead] = nil
    qhead = qhead + 1
  end
  if qhead > qtail and qhead > 1 then queue, qhead, qtail = {}, 1, 0 end
  if lastT then
    local b = buffered()
    if not st.bufMinNow or b < st.bufMinNow then st.bufMinNow = b end
  end
end

-- ---------------------------------------------------------- connection

local sock, buf, lastData, retryAt = nil, "", 0, 0

local function disconnect(why)
  if sock then pcall(sock.close, sock) end
  sock = nil
  buf = ""
  queue, qhead, qtail, lastT = {}, 1, 0, nil
  offset, syncMin = nil, nil
  if card then pcall(synth.off) end
  st.reconnects = st.reconnects + 1
  status = why .. " - retrying in " .. RETRY_MS // 1000 .. " s"
  if quiet then print("radio: " .. status) end
  retryAt = sys.millis() + RETRY_MS
end

local function connect()
  status = "Tuning in to " .. host .. "..."
  local s, err = net.connect(host, port, 5000)
  if not s then
    disconnect("Cannot reach " .. host .. ": " .. tostring(err))
    return
  end
  sock, buf, lastData = s, "", sys.millis()
  status = nil
end

local function pump()
  if not sock then
    if sys.millis() >= retryAt then connect() end
    return
  end
  local data = sock:recv(4096)
  if data == nil then
    disconnect("The station went off air")
    return
  end
  local ms = sys.millis()
  if #data > 0 then
    st.gapMaxNow = math.max(st.gapMaxNow, ms - lastData)
    lastData = ms
    buf = buf .. data
    while true do
      local line, rest = buf:match("^([^\n]*)\n(.*)$")
      if not line then break end
      buf = rest
      parse(line)
    end
  else
    st.gapMaxNow = math.max(st.gapMaxNow, ms - lastData)
    if ms - lastData > NO_DATA_MS then
      disconnect("No signal from " .. host)
    end
  end
end

-- -------------------------------------------------------------- screen

local COLS, ROWS = term.cols(), term.rows()
local TITLE, HEAD, TEXT, DIM, BRIGHT, WARN, BAR = 0x1F, 0x0E, 0x07, 0x08, 0x0F, 0x0C, 0x0A

local scr = {}
do
  local bc, ba, fc, fa = {}, {}, {}, {}
  function scr.clear() bc, ba = {}, {} end
  function scr.put(x, y, s, a)
    local n = 0
    for _, c in utf8.codes(s) do
      local cx = x + n
      if cx >= 0 and cx < COLS and y >= 1 and y < ROWS then
        local k = y * COLS + cx + 1
        bc[k], ba[k] = utf8.char(c), a or TEXT
      end
      n = n + 1
    end
    return n
  end
  function scr.flush()
    for y = 1, ROWS - 1 do
      for x = 0, COLS - 1 do
        local k = y * COLS + x + 1
        local ch, a = bc[k] or " ", ba[k] or TEXT
        if ch ~= fc[k] or a ~= fa[k] then
          term.cell(x, y, ch, a)
          fc[k], fa[k] = ch, a
        end
      end
    end
  end
end

local ROLES = {"lead", "chords", "bass", "drums"}

local function bar(n, width)
  n = math.max(0, math.min(width, n))
  return string.rep("\u{2588}", n) .. string.rep("\u{00B7}", width - n)
end

local function secs(ms) return string.format("%.1f s", (ms or 0) / 1000) end

local function draw()
  scr.clear()
  local head = " " .. station:upper() .. "  " .. host .. (port ~= DEFAULT_PORT and ":" .. port or "")
  scr.put(0, 1, head .. string.rep(" ", math.max(0, COLS - utf8.len(head))), TITLE)

  local y = 3
  if track then
    scr.put(2, y, track.title, BRIGHT)
    local now = airNow()
    local el = now and math.max(0, now - track.t) // 1000 or 0
    scr.put(2, y + 1, string.format("%s major  %d bpm  %d:%02d", track.key, track.bpm, el // 60, el % 60), DIM)
  else
    scr.put(2, y, "...", DIM)
  end
  scr.put(2, y + 2, string.format("%d listening", listeners), DIM)

  y = y + 4
  local width = math.max(8, math.min(24, COLS - 22))
  local ms = sys.millis()
  for v = 1, VOICES do
    local m = meter[v]
    local level, label = 0, ""
    if m then
      local left = 1 - (ms - m.start) / (m.ms + 250)
      if left > 0 then level = math.floor(width * left * m.vol / 15 + 0.5) end
      if left > 0 then label = m.label end
    end
    scr.put(2, y, string.format("%-7s", ROLES[v] or ("voice " .. v)), TEXT)
    scr.put(10, y, string.format("%-8s", label), HEAD)
    scr.put(19, y, bar(level, width), BAR)
    y = y + 1
  end

  y = y + 1
  scr.put(2, y, "volume", TEXT)
  scr.put(10, y, muted and "muted" or string.format("%2d/15", master), muted and WARN or HEAD)
  scr.put(19, y, bar(muted and 0 or math.floor(master * width / 15 + 0.5), width), muted and DIM or BAR)

  -- Signal: the buffer bar spans 0..4 s; under 0.5 s it turns red.
  y = y + 2
  scr.put(2, y, "SIGNAL", HEAD)
  y = y + 1
  local b = buffered()
  local low = sock and b < 500
  scr.put(2, y, "buffer", TEXT)
  scr.put(10, y, string.format("%-8s", secs(b)), low and WARN or HEAD)
  scr.put(19, y, bar(math.floor(b * width / 4000 + 0.5), width), low and WARN or BAR)
  y = y + 1
  scr.put(2, y, string.format("min %s  silence %s  jitter %d ms",
    st.bufMin and secs(st.bufMin) or "-", secs(st.gapMax), st.jitter), DIM)
  y = y + 1
  scr.put(2, y, string.format("late %d/%d  reconnects %d  loop %d ms  queue %d",
    st.late, st.late + st.played, st.reconnects, st.loopMax, qtail - qhead + 1),
    st.late > 0 and WARN or DIM)

  y = y + 2
  if not card then
    scr.put(2, y, "No sound card: the songs scroll by in silence", WARN)
    y = y + 1
  end
  if status then scr.put(2, y, status, WARN) end
  scr.put(2, ROWS - 2, "+/- volume  M mute  Esc quit", DIM)
  scr.flush()
end

-- ---------------------------------------------------------------- main

local function onKey(e)
  if e.type == "char" then
    local c = e.ch:lower()
    if c == "q" then return "quit"
    elseif c == "+" or c == "=" then master, muted = math.min(15, master + 1), false
    elseif c == "-" then master, muted = math.max(0, master - 1), false
    elseif c == "m" then muted = not muted
    else return end
    store.set("radio_volume", tostring(master))
    setMaster()
  elseif e.type == "key" then
    if e.key == "esc" then return "quit"
    elseif e.key == "up" then master, muted = math.min(15, master + 1), false
    elseif e.key == "down" then master, muted = math.max(0, master - 1), false
    else return end
    store.set("radio_volume", tostring(master))
    setMaster()
  end
end

local function main()
  setMaster()
  if quiet and not card then print("radio: no sound card, nothing to hear") return end
  if not quiet then
    term.cls()
    term.showcursor(false)
  end
  connect()
  if quiet and status then print(status) end
  local lastDraw, lastLoop, lastLate = 0, sys.millis(), 0
  st.windowStart = lastLoop
  while true do
    pump()
    playDue()
    if not quiet then
      for e in key.poll do
        if onKey(e) == "quit" then return end
      end
    end
    local now = sys.millis()
    st.loopMaxNow = math.max(st.loopMaxNow, now - lastLoop)
    lastLoop = now
    rollStats(now)
    if not quiet and now - lastDraw >= 80 then
      lastDraw = now
      draw()
    elseif quiet and st.late > lastLate and now - lastDraw >= 10000 then
      lastDraw, lastLate = now, st.late
      print(string.format("radio: %d late notes, buffer min %s, silence %s, loop %d ms",
        st.late, st.bufMin and secs(st.bufMin) or "-", secs(st.gapMax), st.loopMax))
    end
    sys.sleep(2)
  end
end

local ok, err = pcall(main)
if sock then pcall(sock.close, sock) end
if card then pcall(synth.off) end
if not quiet then
  term.cls()
  term.showcursor(true)
end
if not ok then error(err, 0) end
