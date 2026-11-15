-- cycles: live-coding of music patterns on the Termina sound card, after
-- Strudel (strudel.cc) and TidalCycles. Type a pattern, press F5: it plays,
-- and plays the new version at the next note each time F5 is pressed again.
--
--   cycles [file]         edits /music/live.cyc by default (a new file
--                         starts with an example)
--   cycles play <file>    plays a file without the editor (any key stops)
--
-- Keys: F5 or Ctrl+Enter play, F6 stops, F2 next example, Ctrl+S saves,
-- Esc quits.
if not termina or not termina.synth or not termina.synth.at then
  print("cycles needs TERMINA 8.11.0 or later")
  return
end
local term, key, sys, fs, synth = termina.term, termina.key, termina.sys, termina.fs, termina.synth
local dsl = require "cycles.dsl"
local mini = require "cycles.mini"
local Player = require "cycles.player"
local examples = require "cycles.examples"

local args = {...}

local function readFile(path)
  if not fs.exists(path) then return nil, "no such file" end
  return fs.read(path)
end

local function writeFile(path, text)
  local dir = path:match("^(.*)/[^/]*$")
  if dir and dir ~= "" and not fs.isdir(dir) then fs.mkdir(dir) end
  return fs.write(path, text)
end

local function startPlayer()
  local p = Player.new(synth, sys.millis)
  synth.master(15)
  return p
end

-- --------------------------------------------------------------- headless

if args[1] == "play" then
  local path = args[2]
  if not path then
    print("usage: cycles play <file>")
    return
  end
  local text, err = readFile(path)
  if not text then
    print("cycles: " .. path .. ": " .. tostring(err))
    return
  end
  local r, why = dsl.eval(text)
  if not r then
    print("cycles: " .. tostring(why))
    return
  end
  for _, line in ipairs(r.log) do print(line) end
  if not r.pattern then
    print("cycles: nothing to play")
    return
  end
  local player = startPlayer()
  if r.cps then player:setCps(r.cps) end
  player:setPattern(r.pattern)
  if not synth.present() then print("No sound card: nothing will be heard") end
  print("Playing " .. path .. " - any key stops")
  local ok, e = pcall(function()
    while true do
      local qerr = player:tick()
      if qerr then error(qerr, 0) end
      for ev in key.poll do
        if ev.type == "char" or ev.type == "key" then return end
      end
      sys.sleep(20)
    end
  end)
  player:hush()
  if not ok then print("cycles: " .. tostring(e)) end
  return
end

-- ----------------------------------------------------------------- editor

local COLS, ROWS = term.cols(), term.rows()
if COLS < 40 or ROWS < 12 then
  print("cycles needs a screen of 40x12 or more")
  return
end

local PATH = args[1] or "/music/live.cyc"
if not PATH:find("%.[^/]*$") then PATH = PATH .. ".cyc" end

local TITLE, TITLE_ON, TEXT, DIM, STR, COMMENT = 0x1F, 0x2F, 0x07, 0x08, 0x0B, 0x02
local OK, WARN, PLAYING, BAR = 0x0A, 0x0C, 0x0E, 0x70

local TOP = 2                 -- first row of the code
local STATUS = ROWS - 3       -- status rows: STATUS .. ROWS - 1
local function viewRows() return STATUS - TOP end

-- Drawing goes to a back buffer; flush() sends only the cells that changed.
local scr = {}
do
  local bc, ba, fc, fa = {}, {}, {}, {}
  function scr.clear() bc, ba = {}, {} end
  -- Clears rows y0..y1 only (the status rows, while the code stays).
  function scr.clearRows(y0, y1)
    for k = y0 * COLS + 1, (y1 + 1) * COLS do bc[k], ba[k] = nil, nil end
  end
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
  function scr.bar(y, a)
    for x = 0, COLS - 1 do scr.put(x, y, " ", a) end
  end
  function scr.flush(y0, y1)
    for y = y0 or 1, y1 or ROWS - 1 do
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

-- ------------------------------------------------------------------ state

local lines = {""}
local cx, cy = 1, 1          -- cursor: column (byte, 1-based) and line
local top, left = 1, 0       -- first line and column on screen
local modified, quitting = false, false
local message, messageAttr = "", TEXT
local example = 0
local player
local playing = false
local flashUntil = 0
local card = synth.version()

local function say(text, a)
  message, messageAttr = text:gsub("\n", " "), a or TEXT
end

local function setText(text)
  lines = {}
  for line in (text:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  if #lines > 1 and lines[#lines] == "" then lines[#lines] = nil end
  if #lines == 0 then lines = {""} end
  cx, cy, top, left = 1, 1, 1, 0
end

local function text() return table.concat(lines, "\n") .. "\n" end

-- -------------------------------------------------------------- drawing

-- Colors of one line: mini-notation strings and comments. state is what
-- goes on from the line before (a `string` or a /* comment */); returns
-- the state at the end of the line. Without y, only the state is computed.
local function drawLine(y, s, state)
  if not utf8.len(s) then s = s:gsub("[\128-\255]", "?") end
  local x = -left
  local quote = state == "`" and "`" or nil
  local block = state == "/*"
  local skip = 0
  for i, code in utf8.codes(s) do
    local c = utf8.char(code)
    local two = s:sub(i, i + 1)
    local attr = TEXT
    if skip > 0 then
      skip, attr = skip - 1, COMMENT
    elseif block then
      attr = COMMENT
      if two == "*/" then block, skip = false, 1 end
    elseif quote then
      attr = STR
      if c == quote then quote = nil end
    elseif two == "--" or two == "//" then
      if y then scr.put(x, y, s:sub(i), COMMENT) end
      return nil
    elseif two == "/*" then
      block, attr = true, COMMENT
    elseif c == '"' or c == "'" or c == "`" then
      quote, attr = c, STR
    end
    if y then scr.put(x, y, c, attr) end
    x = x + 1
  end
  if block then return "/*" end
  if quote == "`" then return "`" end
end

local function voicesText()
  local st = card and synth.status() or 0
  local t = {}
  for v = 1, 4 do t[v] = (st & (1 << (v - 1)) ~= 0) and "\u{25A0}" or "\u{00B7}" end
  return table.concat(t, " ")
end

local HELP = "F5 play  F6 stop  F2 example  ^S save  Esc quit"

-- The status rows only: while music plays, they change and the code does
-- not (redrawing all of it would cost the ESP32 time the music needs).
local function drawStatus()
  scr.clearRows(STATUS, ROWS - 1)
  scr.bar(STATUS, BAR)
  local state
  if playing and player.pattern then
    state = string.format(" \u{25BA} cycle %.1f", player:now())
  else
    state = " \u{25A0} stopped"
  end
  local info = string.format("%s  cps %s  voices %s", state, player:cps(), card and voicesText() or "(no card)")
  if card then
    local _, late = synth.stats()
    info = info .. string.format("  late %dms", late or 0)
  end
  scr.put(0, STATUS, info, BAR)
  scr.put(1, STATUS + 1, message, messageAttr)
  scr.put(1, STATUS + 2, HELP, DIM)
end

local function draw(statusOnly)
  if statusOnly then
    drawStatus()
    scr.flush(STATUS, ROWS - 1)
    return
  end
  scr.clear()
  local now = sys.millis()
  local ta = now < flashUntil and TITLE_ON or TITLE
  scr.bar(1, ta)
  scr.put(1, 1, "CYCLES", ta)
  scr.put(9, 1, PATH:match("[^/]*$") .. (modified and "*" or ""), ta)
  local right = string.format("Ln %d Col %d", cy, cx)
  scr.put(COLS - 1 - #right, 1, right, ta)

  local rows = viewRows()
  local st
  for k = 1, top - 1 do st = drawLine(nil, lines[k], st) end  -- strings and comments above
  for r = 0, rows - 1 do
    local l = lines[top + r]
    if not l then break end
    st = drawLine(TOP + r, l, st)
  end
  drawStatus()
  scr.flush()
  -- The text cursor.
  local sx, sy = (utf8.len(lines[cy]:sub(1, cx - 1)) or cx - 1) - left, TOP + cy - top
  if sx >= 0 and sx < COLS and sy >= TOP and sy < STATUS then
    term.cursor(sx, sy)
    term.showcursor(true)
  else
    term.showcursor(false)
  end
end

-- -------------------------------------------------------------- editing

local function clampCursor()
  cy = math.max(1, math.min(#lines, cy))
  cx = math.max(1, math.min(#lines[cy] + 1, cx))
  local rows = viewRows()
  if cy < top then top = cy end
  if cy >= top + rows then top = cy - rows + 1 end
  if cx - 1 < left then left = cx - 1 end
  if cx - 1 >= left + COLS - 1 then left = cx - COLS + 1 end
end

local function changed()
  modified, quitting = true, false
end

local function insert(s)
  local l = lines[cy]
  lines[cy] = l:sub(1, cx - 1) .. s .. l:sub(cx)
  cx = cx + #s
  changed()
end

local function newline()
  local l = lines[cy]
  local indent = l:match("^%s*")
  if cx <= #indent then indent = l:sub(1, cx - 1) end
  lines[cy] = l:sub(1, cx - 1)
  table.insert(lines, cy + 1, indent .. l:sub(cx))
  cy, cx = cy + 1, #indent + 1
  changed()
end

local function backspace()
  if cx > 1 then
    local l = lines[cy]
    -- A whole UTF-8 character.
    local s = cx - 1
    while s > 1 and (l:byte(s) & 0xC0) == 0x80 do s = s - 1 end
    lines[cy] = l:sub(1, s - 1) .. l:sub(cx)
    cx = s
  elseif cy > 1 then
    cx = #lines[cy - 1] + 1
    lines[cy - 1] = lines[cy - 1] .. lines[cy]
    table.remove(lines, cy)
    cy = cy - 1
  else
    return
  end
  changed()
end

local function delete()
  local l = lines[cy]
  if cx <= #l then
    local e = cx + 1
    while e <= #l and (l:byte(e) & 0xC0) == 0x80 do e = e + 1 end
    lines[cy] = l:sub(1, cx - 1) .. l:sub(e)
  elseif cy < #lines then
    lines[cy] = l .. lines[cy + 1]
    table.remove(lines, cy + 1)
  else
    return
  end
  changed()
end

local function moveH(d)
  local l = lines[cy]
  if d < 0 then
    if cx > 1 then
      cx = cx - 1
      while cx > 1 and (l:byte(cx) & 0xC0) == 0x80 do cx = cx - 1 end
    elseif cy > 1 then
      cy = cy - 1
      cx = #lines[cy] + 1
    end
  else
    if cx <= #l then
      cx = cx + 1
      while cx <= #l and (l:byte(cx) & 0xC0) == 0x80 do cx = cx + 1 end
    elseif cy < #lines then
      cy, cx = cy + 1, 1
    end
  end
end

-- --------------------------------------------------------------- playing

-- Running a long piece of code takes the ESP32 a second or more: the music
-- playing goes on meanwhile (queued further ahead first, then topped up
-- each time a new mini-notation string is parsed).
local function evaluate()
  if playing then
    pcall(player.tick, player, 800)
    mini.busy = function() pcall(player.tick, player) end
  end
  local r, err = dsl.eval(text())
  mini.busy = nil
  if not r then
    say(err, WARN)
    return
  end
  if not r.pattern then
    say("Nothing to play: end with a pattern, like note(\"c e g\")", WARN)
    return
  end
  local ok, e = pcall(function()
    if r.cps then player:setCps(r.cps) end
    player:setPattern(r.pattern)
  end)
  if not ok then
    say(tostring(e), WARN)
    return
  end
  playing = true
  flashUntil = sys.millis() + 150
  if #r.log > 0 then
    say(r.log[#r.log])
  else
    say(card and "Playing" or "Playing, but there is no sound card to hear it", card and OK or WARN)
  end
end

local function stop()
  player:hush()
  playing = false
  say("Stopped")
end

local function save()
  local ok, err = writeFile(PATH, text())
  if ok then
    modified = false
    say("Saved " .. PATH, OK)
  else
    say("Cannot save " .. PATH .. ": " .. tostring(err), WARN)
  end
end

local function nextExample()
  example = example % #examples + 1
  local ex = examples[example]
  setText(ex[2])
  changed()
  say("Example " .. example .. "/" .. #examples .. ": " .. ex[1] .. " (F5 plays it)", OK)
end

local function onKey(e)
  local k = e.key
  if e.ctrl then
    if k == "s" then save()
    elseif k == "enter" or k == "r" then evaluate()
    elseif k == "." then stop()
    elseif k == "home" then cx, cy = 1, 1
    elseif k == "end" then cy = #lines cx = #lines[cy] + 1
    elseif k == "k" then  -- deletes the line
      if #lines > 1 then table.remove(lines, cy) else lines[1] = "" end
      changed()
    end
    return
  end
  if k == "f5" then evaluate()
  elseif k == "f6" then stop()
  elseif k == "f2" then nextExample()
  elseif k == "esc" then
    if modified and not quitting then
      quitting = true
      say("Unsaved changes: Esc again quits, Ctrl+S saves", WARN)
    else
      return "quit"
    end
  elseif k == "enter" then newline()
  elseif k == "backspace" then backspace()
  elseif k == "delete" then delete()
  elseif k == "tab" then insert("  ")
  elseif k == "left" then moveH(-1)
  elseif k == "right" then moveH(1)
  elseif k == "up" then cy = cy - 1
  elseif k == "down" then cy = cy + 1
  elseif k == "home" then  -- the indent first, then the first column
    local ind = #lines[cy]:match("^%s*") + 1
    cx = cx == ind and 1 or ind
  elseif k == "end" then cx = #lines[cy] + 1
  elseif k == "pgup" then cy = cy - viewRows()
  elseif k == "pgdn" then cy = cy + viewRows()
  end
end

local function main()
  term.cls()
  local loaded, err = readFile(PATH)
  if loaded then
    setText(loaded)
    say("Loaded " .. PATH .. " - F5 plays it")
  else
    example = 1
    setText(examples[1][2])
    say(err == "no such file" and "New file: an example to start from (F5 plays it, F2 shows more)" or
        "Cannot read " .. PATH .. ": " .. tostring(err), err == "no such file" and OK or WARN)
  end
  if not card then say("No sound card: patterns run but nothing is heard", WARN) end
  player = startPlayer()
  draw()
  local lastStatus = 0
  local flashing = false
  while true do
    local dirty, status = false, false
    for e in key.poll do
      dirty = true
      if e.type == "char" then
        insert(e.ch)
      elseif e.type == "key" then
        if onKey(e) == "quit" then return end
      elseif e.type == "mouse" and e.down and e.y >= TOP and e.y < STATUS then
        cy = top + e.y - TOP
        cy = math.max(1, math.min(#lines, cy))
        cx = e.x + left + 1
      end
      clampCursor()
    end
    local qerr, warn = player:tick()
    if qerr then
      playing = false
      say(qerr, WARN)
      status = true
    elseif warn and warn ~= message then
      say(warn, WARN)
      status = true
    end
    local now = sys.millis()
    -- The status line 4 times a second while playing.
    if playing and now - lastStatus >= 250 then status = true end
    -- The title flashes when the code is played: once on, once off.
    local flash = now < flashUntil
    if flash ~= flashing then
      flashing, dirty = flash, true
    end
    if dirty then
      draw()
      lastStatus = now
    elseif status then
      draw(true)
      lastStatus = now
    end
    sys.sleep(10)
  end
end

local ok, err = pcall(main)
if player then player:hush() end
term.cls()
term.showcursor(true)
if not ok then error(err, 0) end
