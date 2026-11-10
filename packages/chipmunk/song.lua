-- chipmunk.song: songs (instruments, patterns, order), files and playback
-- on the sound card's 4 voices (termina.synth).
local synth, fs = termina.synth, termina.fs

local M = {}

M.CHANNELS = 4
M.ROWS = 32          -- rows of a new pattern
M.MAX_PATTERNS = 16
M.WAVES = {"pulse", "triangle", "saw", "noise"}
M.FIELDS = {"wave", "duty", "vol", "attack", "decay", "sustain", "release"}

-- ------------------------------------------------------------------ notes

local NAMES = {"C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"}

function M.noteName(n)  -- 60 → "C-4", 0 → "===" (note off)
  if n == 0 then return "===" end
  return NAMES[n % 12 + 1] .. (n // 12 - 1)
end

function M.hz(n) return 440 * 2 ^ ((n - 69) / 12) end

-- ------------------------------------------------------------ instruments

local function inst(name, wave, duty, vol, a, d, s, r)
  return {name = name, wave = wave, duty = duty, vol = vol, attack = a, decay = d, sustain = s, release = r}
end

function M.defaultInstruments()
  return {
    inst("lead", 1, 64, 12, 0, 6, 8, 5),
    inst("bass", 2, 128, 15, 0, 8, 12, 3),
    inst("arp", 1, 32, 8, 0, 5, 0, 2),
    inst("kick", 2, 128, 15, 0, 5, 0, 0),
    inst("snare", 4, 128, 13, 0, 6, 0, 4),
    inst("hat", 4, 128, 7, 0, 3, 0, 1),
    inst("pad", 3, 128, 8, 6, 8, 10, 9),
    inst("square", 1, 128, 12, 0, 0, 15, 2),
  }
end

-- Field limits for the editor: wave 1..4, duty 0..255, the others 0..15.
function M.limits(field)
  if field == "wave" then return 1, 4 end
  if field == "duty" then return 0, 255 end
  return 0, 15
end

-- --------------------------------------------------------------- patterns

-- A pattern: {len = rows, [row * 4 + ch] = {note, inst}} (row from 0, ch 1..4).
function M.newPattern(len) return {len = len or M.ROWS} end

function M.cell(p, row, ch) return p[row * M.CHANNELS + ch] end

function M.setCell(p, row, ch, c) p[row * M.CHANNELS + ch] = c end

function M.new()
  local s = {bpm = 125, instruments = M.defaultInstruments(), patterns = {M.newPattern()}, order = {1}}
  return s
end

function M.pattern(s, n)  -- creates it when missing
  if not s.patterns[n] then s.patterns[n] = M.newPattern() end
  return s.patterns[n]
end

-- The demo: two bars in A minor (Am F C G), lead, bass, arpeggio and drums.
function M.demo()
  local s = M.new()
  local p = s.patterns[1]
  local function put(row, ch, note, i) M.setCell(p, row, ch, {note, i}) end
  local lead = {[0] = 76, [3] = 74, [4] = 72, [6] = 69, [8] = 72, [10] = 69, [12] = 65, [14] = 69,
                [16] = 67, [19] = 72, [20] = 76, [22] = 79, [24] = 79, [26] = 77, [28] = 76, [30] = 74}
  for row, n in pairs(lead) do put(row, 1, n, 1) end
  local bass = {45, 41, 48, 43}
  local chords = {{57, 60, 64}, {53, 57, 60}, {60, 64, 67}, {55, 59, 62}}
  for bar = 0, 3 do
    put(bar * 8, 2, bass[bar + 1], 2)
    put(bar * 8 + 4, 2, bass[bar + 1], 2)
    put(bar * 8, 4, 36, 4)
    put(bar * 8 + 4, 4, 100, 5)
    put(bar * 8 + 2, 4, 108, 6)
    put(bar * 8 + 6, 4, 108, 6)
    for k = 0, 7 do put(bar * 8 + k, 3, chords[bar + 1][k % 3 + 1], 3) end
  end
  return s
end

-- ------------------------------------------------------------------ files

local function serialize(v, out, indent)
  local t = type(v)
  if t == "number" or t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "string" then
    out[#out + 1] = string.format("%q", v)
  elseif t == "table" then
    out[#out + 1] = "{"
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then return a < b end
      return type(a) == "number"
    end)
    for _, k in ipairs(keys) do
      out[#out + 1] = "\n" .. indent .. "  "
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        out[#out + 1] = k .. " = "
      else
        out[#out + 1] = "["
        serialize(k, out, "")
        out[#out + 1] = "] = "
      end
      serialize(v[k], out, indent .. "  ")
      out[#out + 1] = ","
    end
    out[#out + 1] = "\n" .. indent .. "}"
  end
end

function M.save(s, path)
  local out = {"-- chipmunk song\nreturn "}
  serialize(s, out, "")
  out[#out + 1] = "\n"
  local dir = path:match("^(.*)/[^/]*$")
  if dir and dir ~= "" and not fs.isdir(dir) then fs.mkdir(dir) end
  return fs.write(path, table.concat(out))
end

function M.load(path)
  local text = fs.exists(path) and fs.read(path)
  if not text then return nil, "no such file" end
  local chunk, err = load(text, "=" .. path, "t", {})
  if not chunk then return nil, err end
  local ok, s = pcall(chunk)
  if not ok or type(s) ~= "table" then return nil, "not a chipmunk song" end
  s.bpm = math.max(30, math.min(300, tonumber(s.bpm) or 125))
  s.instruments = s.instruments or M.defaultInstruments()
  s.patterns = s.patterns or {}
  s.order = s.order or {1}
  if #s.order == 0 then s.order = {1} end
  for _, n in ipairs(s.order) do M.pattern(s, n) end
  return s
end

-- --------------------------------------------------------------- playback

local P = {playing = false, sent = {}}
M.player = P

local function sendInstrument(ch, i, s)
  if P.sent[ch] == i then return end
  local d = s.instruments[i]
  if not d then return end
  P.sent[ch] = i
  synth.voice(ch, {wave = M.WAVES[d.wave], duty = d.duty, vol = d.vol, attack = d.attack,
                   decay = d.decay, sustain = d.sustain, release = d.release})
end

-- Plays one cell on its channel: a note (with its instrument), or note off.
function M.play(s, ch, c, ms)
  if not c then return end
  if c[1] == 0 then
    synth.off(ch)
    return
  end
  sendInstrument(ch, c[2], s)
  synth.note(ch, M.hz(c[1]), ms)
end

-- The instrument was edited: send it again on its next note.
function M.touched() P.sent = {} end

-- mode "song" walks the order list from slot `slot`; "pattern" loops the
-- pattern of that slot.
function M.start(s, mode, slot, row)
  P.playing, P.mode, P.slot, P.row = true, mode, slot, row or 0
  P.next = termina.sys.millis()
  P.sent = {}
end

function M.stop()
  if P.playing then synth.off() end
  P.playing = false
end

function M.rowMs(s) return 60000 / (s.bpm * 4) end

-- Plays the rows that are due. Returns true when the position moved.
function M.update(s, now)
  if not P.playing or now < P.next then return false end
  local p = s.patterns[s.order[P.slot]]
  for ch = 1, M.CHANNELS do M.play(s, ch, M.cell(p, P.row, ch)) end
  P.playingSlot, P.playingRow = P.slot, P.row
  P.next = P.next + M.rowMs(s)
  if now > P.next + 500 then P.next = now end  -- fell far behind: do not rush
  P.row = P.row + 1
  if P.row >= p.len then
    P.row = 0
    if P.mode == "song" then P.slot = P.slot % #s.order + 1 end
  end
  return true
end

return M
