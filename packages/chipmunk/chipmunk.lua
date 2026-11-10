-- chipmunk: a 4-channel chiptune tracker for the Termina sound card (the
-- ATtiny85 synthesizer, termina.synth). Eight instruments (pulse with a duty
-- cycle, triangle, sawtooth or noise, with an ADSR envelope), patterns of 32
-- rows, and an order list that chains them into a song.
--
--   chipmunk [file]     edits /music/song.chp by default; a new file starts
--                       with a demo
--
-- Keys: the keyboard is a piano (two octaves, like the trackers of the 90s),
-- Tab moves between the pattern, the instruments and the order list,
-- Space plays the pattern, F5 the song, Ctrl+S saves, Esc quits.
if not termina or not termina.synth then
  print("chipmunk needs TERMINA 8.5.0 or later")
  return
end
local term, key, sys, store, synth = termina.term, termina.key, termina.sys, termina.store, termina.synth
local song = require "chipmunk.song"

local COLS, ROWS = term.cols(), term.rows()
if COLS < 60 or ROWS < 32 then
  print("chipmunk needs a screen of 60x32 or more")
  return
end

local PATH = (...) or "/music/song.chp"
if not PATH:find("%.") then PATH = PATH .. ".chp" end

local TITLE, HEAD, TEXT, DIM, BRIGHT = 0x1F, 0x0E, 0x07, 0x08, 0x0F
local SEL, PLAY, BEAT, WARN, NOTE = 0x70, 0x2F, 0x0B, 0x0C, 0x0A

-- ---------------------------------------------------------------- screen

-- Drawing goes to a back buffer; flush() sends only the cells that changed.
local scr = {}
do
  local bc, ba, fc, fa = {}, {}, {}, {}

  function scr.clear()
    bc, ba = {}, {}
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

-- ----------------------------------------------------------------- state

local S                      -- the song
local focus = "pattern"      -- "pattern", "inst" or "order"
local slot = 1               -- order slot being edited (its pattern is shown)
local crow, cch = 0, 1       -- pattern cursor
local top = 0                -- first pattern row on screen
local curInst = 1
local field = 1              -- instrument field being edited
local octave = 4
local modified = false
local quitting = false
local message, messageAttr = "", TEXT
local card = synth.version()
local held = {}              -- [ch] = key name of a note sounding while held
local layout = store.get("chipmunk_kbd") or "qwerty"

local function say(text, a)
  message, messageAttr = text, a or TEXT
end

local function pat() return song.pattern(S, S.order[slot]) end

-- ----------------------------------------------------------------- piano

-- Character → semitone above C of the current octave.
local PIANO = {
  qwerty = {
    z = 0, s = 1, x = 2, d = 3, c = 4, v = 5, g = 6, b = 7, h = 8, n = 9, j = 10, m = 11,
    [","] = 12, l = 13, ["."] = 14, [";"] = 15, ["/"] = 16,
    q = 12, ["2"] = 13, w = 14, ["3"] = 15, e = 16, r = 17, ["5"] = 18, t = 19, ["6"] = 20,
    y = 21, ["7"] = 22, u = 23, i = 24, ["9"] = 25, o = 26, ["0"] = 27, p = 28,
  },
  azerty = {
    w = 0, s = 1, x = 2, d = 3, c = 4, v = 5, g = 6, b = 7, h = 8, n = 9, j = 10, [","] = 11,
    [";"] = 12, l = 13, [":"] = 14, m = 15, ["!"] = 16,
    a = 12, ["é"] = 13, z = 14, ['"'] = 15, e = 16, r = 17, ["("] = 18, t = 19, ["-"] = 20,
    y = 21, ["è"] = 22, u = 23, i = 24, ["ç"] = 25, o = 26, ["à"] = 27, p = 28,
  },
}

local function pianoNote(ch)
  local semi = PIANO[layout][ch]
  if not semi then return nil end
  local n = 12 * (octave + 1) + semi
  return n >= 1 and n <= 127 and n or nil
end

-- Plays a note while its key is held (key.held), or for 250 ms when the
-- keyboard does not report held keys.
local function preview(ch, note, inst, keyName)
  local c = {note, inst}
  if keyName and keyName:match("^[%w]$") and key.held(keyName) then
    song.play(S, ch, c)
    held[ch] = keyName
  else
    song.play(S, ch, c, 250)
    held[ch] = nil
  end
end

local function releaseHeld()
  for ch, name in pairs(held) do
    if not key.held(name) then
      synth.off(ch)
      held[ch] = nil
    end
  end
end

-- ------------------------------------------------------------------ drawing

local GRID_Y = 18
local CELL_W = 10
local function gridRows() return ROWS - 5 - GRID_Y end

local function pct(duty) return string.format("%3d%%", (duty * 100 + 128) // 256) end

local FIELD_X = {13, 22, 30, 36, 41, 46, 51}  -- columns of the instrument fields

local function drawTitle()
  scr.bar(1, TITLE)
  scr.put(1, 1, "CHIPMUNK", TITLE)
  local name = PATH:match("[^/]*$") .. (modified and "*" or "")
  scr.put(11, 1, name, TITLE)
  local right = string.format("BPM %d  Oct %d  %s  %s", S.bpm, octave, layout:upper(),
                              card and ("card v" .. card) or "no sound card")
  scr.put(COLS - 1 - utf8.len(right), 1, right, TITLE)
end

local function drawInstruments()
  scr.put(1, 3, "INSTRUMENTS", focus == "inst" and HEAD or DIM)
  scr.put(13, 3, "wave     duty    vol   A    D    S    R", DIM)
  for i, d in ipairs(S.instruments) do
    local y = 3 + i
    local cur = i == curInst
    scr.put(1, y, string.format("%d %-8s", i, d.name), cur and BRIGHT or TEXT)
    local vals = {song.WAVES[d.wave], d.wave == 1 and pct(d.duty) or "  - ", string.format("%2d", d.vol),
                  string.format("%2d", d.attack), string.format("%2d", d.decay),
                  string.format("%2d", d.sustain), string.format("%2d", d.release)}
    for f, v in ipairs(vals) do
      local a = cur and BRIGHT or TEXT
      if cur and focus == "inst" and f == field then a = SEL end
      scr.put(FIELD_X[f], y, v, a)
    end
    if cur then scr.put(0, y, ">", HEAD) end
  end
end

local function drawOrder()
  scr.put(1, 13, "ORDER", focus == "order" and HEAD or DIM)
  local P = song.player
  local x = 1
  local first = math.max(1, slot - (COLS - 4) // 4 + 1)
  for i = first, #S.order do
    if x + 3 > COLS then break end
    local a = TEXT
    if P.playing and P.playingSlot == i then a = PLAY end
    if i == slot then a = focus == "order" and SEL or BRIGHT end
    scr.put(x, 14, string.format("%02d", S.order[i]), a)
    x = x + 4
  end
end

local function drawPattern()
  local p = pat()
  local P = song.player
  scr.put(1, 16, string.format("PATTERN %02d", S.order[slot]), focus == "pattern" and HEAD or DIM)
  scr.put(13, 16, string.format("%d rows  slot %d/%d", p.len, slot, #S.order), DIM)
  local status = card and synth.status() or 0
  for ch = 1, song.CHANNELS do
    local x = 4 + (ch - 1) * CELL_W
    local on = status & (1 << (ch - 1)) ~= 0
    scr.put(x, 17, string.format(" ch%d %s", ch, on and "\u{266A}" or " "), on and NOTE or DIM)
  end
  local n = gridRows()
  if crow < top then top = crow end
  if crow >= top + n then top = crow - n + 1 end
  local playRow = P.playing and S.order[P.playingSlot or 0] == S.order[slot] and P.playingRow
  for i = 0, n - 1 do
    local row = top + i
    local y = GRID_Y + i
    if row >= p.len then break end
    local rowAttr = row % 4 == 0 and BEAT or DIM
    if row == playRow then rowAttr = PLAY end
    scr.put(0, y, string.format("%02d ", row), rowAttr)
    for ch = 1, song.CHANNELS do
      local x = 4 + (ch - 1) * CELL_W
      local c = song.cell(p, row, ch)
      local text = c and string.format(" %s %d  ", song.noteName(c[1]), c[1] == 0 and 0 or c[2])
      if c and c[1] == 0 then text = " ===    " end
      text = text or " ---  .  "
      local a = c and TEXT or DIM
      if row == playRow then a = PLAY end
      if focus == "pattern" and row == crow and ch == cch then a = SEL end
      scr.put(x, y, text, a)
    end
  end
end

-- Three lines of at most 59 characters each: they fit the narrowest screen.
local COMMON = "Space: play/stop  F5: song  Tab: panel  ^S: save  Esc: quit"
local HELP = {
  pattern = {"Piano keys: notes  Enter: note off  Del: clear",
             "F1/F2 instrument  F3/F4 octave  F7/F8 tempo  F9 AZERTY", COMMON},
  inst = {"Up/Down: value  PgUp/PgDn: by 4  Left/Right: field",
          "F1/F2 instrument  F3/F4 octave  piano keys: try it", COMMON},
  order = {"Left/Right: slot  Up/Down: pattern  Ins: add  Del: remove",
           "F7/F8 tempo  F9 QWERTY/AZERTY", COMMON},
}

local function draw()
  scr.clear()
  drawTitle()
  drawInstruments()
  drawOrder()
  drawPattern()
  scr.put(1, ROWS - 4, message, messageAttr)
  for i, line in ipairs(HELP[focus]) do scr.put(1, ROWS - 4 + i, line, DIM) end
  scr.flush()
end

-- ------------------------------------------------------------------ editing

local function changed()
  modified, quitting = true, false
end

local function move(dr, dc)
  local p = pat()
  crow = math.max(0, math.min(p.len - 1, crow + dr))
  if dc ~= 0 then cch = (cch - 1 + dc) % song.CHANNELS + 1 end
end

local function setNote(note)
  song.setCell(pat(), crow, cch, note and {note, note == 0 and 0 or curInst} or nil)
  changed()
end

local function editField(delta)
  local d = S.instruments[curInst]
  local name = song.FIELDS[field]
  local lo, hi = song.limits(name)
  local step = name == "duty" and 16 or 1
  local v = d[name] + delta * step
  if name == "wave" then v = (v - 1) % 4 + 1 end
  d[name] = math.max(lo, math.min(hi, v))
  song.touched()
  changed()
end

local function save()
  local ok, err = song.save(S, PATH)
  if ok then
    modified = false
    say("Saved " .. PATH, NOTE)
  else
    say("Cannot save " .. PATH .. ": " .. tostring(err), WARN)
  end
end

local function togglePlay(mode)
  if song.player.playing then
    song.stop()
    say("Stopped")
  else
    song.start(S, mode, slot, 0)
    say(mode == "song" and "Playing the song" or "Playing pattern " .. S.order[slot])
  end
end

local function onPiano(ch, e)
  local note = pianoNote(ch)
  if not note then return false end
  if focus == "pattern" then
    setNote(note)
    preview(cch, note, curInst, ch)
    move(1, 0)
  else
    preview(focus == "inst" and 1 or cch, note, curInst, ch)
  end
  return true
end

local function onKey(e)
  local k = e.key
  if e.ctrl and k == "s" then save() return end
  if k == "tab" then
    focus = focus == "pattern" and "inst" or focus == "inst" and "order" or "pattern"
  elseif k == "esc" then
    if song.player.playing then
      song.stop()
      say("Stopped")
    elseif modified and not quitting then
      quitting = true
      say("Unsaved changes: Esc again quits, Ctrl+S saves", WARN)
    else
      return "quit"
    end
  elseif k == "f1" then curInst = (curInst - 2) % #S.instruments + 1
  elseif k == "f2" then curInst = curInst % #S.instruments + 1
  elseif k == "f3" then octave = math.max(0, octave - 1)
  elseif k == "f4" then octave = math.min(8, octave + 1)
  elseif k == "f5" then togglePlay("song")
  elseif k == "f7" then S.bpm = math.max(30, S.bpm - 5) changed()
  elseif k == "f8" then S.bpm = math.min(300, S.bpm + 5) changed()
  elseif k == "f9" then
    layout = layout == "qwerty" and "azerty" or "qwerty"
    store.set("chipmunk_kbd", layout)
    say("Piano keys: " .. layout:upper() .. " layout")
  elseif focus == "pattern" then
    if k == "up" then move(-1, 0)
    elseif k == "down" then move(1, 0)
    elseif k == "left" then move(0, -1)
    elseif k == "right" then move(0, 1)
    elseif k == "pgup" then move(-8, 0)
    elseif k == "pgdn" then move(8, 0)
    elseif k == "home" then crow = 0
    elseif k == "end" then crow = pat().len - 1
    elseif k == "enter" then setNote(0) move(1, 0)
    elseif k == "delete" or k == "backspace" then setNote(nil) move(1, 0)
    end
  elseif focus == "inst" then
    if k == "up" then editField(1)
    elseif k == "down" then editField(-1)
    elseif k == "pgup" then editField(4)
    elseif k == "pgdn" then editField(-4)
    elseif k == "left" then field = (field - 2) % #song.FIELDS + 1
    elseif k == "right" then field = field % #song.FIELDS + 1
    end
  elseif focus == "order" then
    if k == "left" then slot = math.max(1, slot - 1)
    elseif k == "right" then slot = math.min(#S.order, slot + 1)
    elseif k == "up" or k == "down" then
      local n = S.order[slot] + (k == "up" and 1 or -1)
      S.order[slot] = math.max(1, math.min(song.MAX_PATTERNS, n))
      song.pattern(S, S.order[slot])
      changed()
    elseif k == "insert" then
      table.insert(S.order, slot + 1, S.order[slot])
      slot = slot + 1
      changed()
    elseif k == "delete" and #S.order > 1 then
      table.remove(S.order, slot)
      slot = math.min(slot, #S.order)
      changed()
    end
    crow = math.min(crow, pat().len - 1)
  end
end

-- ------------------------------------------------------------------- main

local function main()
  term.showcursor(false)
  term.cls()
  local loaded, err = song.load(PATH)
  if loaded then
    S = loaded
    say("Loaded " .. PATH)
  else
    S = song.demo()
    modified = true
    say(err == "no such file" and "New song: a demo to start from (Space plays it)" or
        "Cannot read " .. PATH .. ": " .. tostring(err) .. " - started a new song", err == "no such file" and NOTE or WARN)
  end
  if not card then say("No sound card: editing only (see the Termina README, Sound card)", WARN) end
  synth.master(15)
  local lastStatus = 0
  draw()
  while true do
    local dirty = false
    for e in key.poll do
      dirty = true
      if e.type == "char" then
        local ch = e.ch:lower()
        if ch == " " then togglePlay("pattern")
        else onPiano(ch, e) end
      elseif e.type == "key" then
        if onKey(e) == "quit" then return end
      end
    end
    releaseHeld()
    if song.update(S, sys.millis()) then
      local P = song.player
      -- Playing the song, the pattern on screen follows it (not while the
      -- order list is being edited).
      if P.mode == "song" and focus ~= "order" then slot = P.playingSlot end
      dirty = true
    end
    local now = sys.millis()
    if card and now - lastStatus >= 100 then  -- channel activity in the header
      lastStatus = now
      dirty = true
    end
    if dirty then draw() end
    sys.sleep(2)
  end
end

local ok, err = pcall(main)
song.stop()
pcall(synth.off)
term.cls()
term.showcursor(true)
if not ok then error(err, 0) end
