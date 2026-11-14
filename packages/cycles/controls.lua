-- cycles.controls: what an event plays. Control functions turn patterns of
-- plain values into patterns of tables ({note = 60, s = "saw"}), and the
-- same names as methods add a parameter to each event:
--
--   note("c e g"):s("saw"):gain(0.7)        Lua
--   note("c e g").s("saw").gain(0.7)        Strudel style, works too
--   n("0 2 4"):scale("C:minor")             scale degrees
local P = require "cycles.pattern"
require "cycles.mini"

local M = {}
local methods = P.methods

-- -------------------------------------------------------------------- notes

local PITCH = {c = 0, d = 2, e = 4, f = 5, g = 7, a = 9, b = 11}

-- "c" -> 48, "c#4" -> 61, "eb" -> 51, "a5" -> 81, 60 -> 60. The octave is 3
-- when missing, like in Strudel.
function M.midi(v)
  if type(v) == "number" then return v end
  if type(v) ~= "string" then return nil end
  local n = tonumber(v)
  if n then return n end
  local l, acc, oct = v:lower():match("^([a-g])([#sbf]*)(%-?%d*)$")
  if not l then return nil end
  local m = PITCH[l]
  for ch in acc:gmatch(".") do m = m + ((ch == "#" or ch == "s") and 1 or -1) end
  return m + 12 * ((tonumber(oct) or 3) + 1)
end

function M.hz(m) return 440 * 2 ^ ((m - 69) / 12) end

P.toNumber = function(v) return M.midi(v) end

-- -------------------------------------------------------------------- scales

M.SCALES = {
  major = {0, 2, 4, 5, 7, 9, 11}, ionian = {0, 2, 4, 5, 7, 9, 11},
  minor = {0, 2, 3, 5, 7, 8, 10}, aeolian = {0, 2, 3, 5, 7, 8, 10},
  dorian = {0, 2, 3, 5, 7, 9, 10}, phrygian = {0, 1, 3, 5, 7, 8, 10},
  lydian = {0, 2, 4, 6, 7, 9, 11}, mixolydian = {0, 2, 4, 5, 7, 9, 10},
  locrian = {0, 1, 3, 5, 6, 8, 10},
  harmonic = {0, 2, 3, 5, 7, 8, 11}, harmonicminor = {0, 2, 3, 5, 7, 8, 11},
  melodicminor = {0, 2, 3, 5, 7, 9, 11},
  pentatonic = {0, 2, 4, 7, 9}, majorpentatonic = {0, 2, 4, 7, 9},
  minorpentatonic = {0, 3, 5, 7, 10},
  blues = {0, 3, 5, 6, 7, 10}, wholetone = {0, 2, 4, 6, 8, 10},
  chromatic = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},
}

-- "C:minor", "a4:minor:pentatonic", "D dorian" -> root midi, steps
local function scaleOf(name)
  name = tostring(name)
  local root, kind = name:match("^([%a#]+%-?%d*)[:%s](.+)$")
  if not root then root, kind = "c", name end
  local steps = M.SCALES[kind:lower():gsub("[%s:_%-]", "")]
  local r = M.midi(root)
  if not steps or not r then error("unknown scale: " .. name, 0) end
  return r, steps
end

local function degree(r, steps, d)
  d = math.floor(tonumber(d) or 0)
  local k = #steps
  return r + 12 * (d // k) + steps[d % k + 1]
end

local function _scale(p, name)
  local r, steps = scaleOf(name)
  return P.fmap(p, function(v)
    if type(v) == "table" then
      local out = {}
      for k, x in pairs(v) do out[k] = x end
      local d = out.n
      if d == nil and type(out.note) == "number" then d = out.note end
      if d ~= nil then
        out.note = degree(r, steps, d)
        out.n = nil
      end
      return out
    end
    return {note = degree(r, steps, v)}
  end)
end
methods.scale = P.patternify(_scale)

-- --------------------------------------------------------------- controls

local function union(a, b)
  local out = {}
  if type(a) == "table" then
    for k, v in pairs(a) do out[k] = v end
  elseif a ~= nil then
    local m = M.midi(a)
    if m then out.note = m else out.s = a end
  end
  for k, v in pairs(b) do out[k] = v end
  return out
end

-- Each control: name -> how a value is stored.
local function number(v) return tonumber(v) end
local CONVERT = {
  note = function(v) return M.midi(v) end,
  n = number,
  s = function(v)
    if type(v) ~= "string" then return tostring(v) end
    local name, idx = v:match("^([^:]+):(%d+)$")
    return name or v, tonumber(idx)
  end,
  gain = number, velocity = number, duty = number, legato = number,
  attack = number, decay = number, sustain = number, release = number,
  voice = number, slide = number, freq = number, postgain = number, lpf = number,
}
local ALIAS = {sound = "s", att = "attack", dec = "decay", sus = "sustain", rel = "release",
               clip = "legato", pw = "duty", v = "voice", cutoff = "lpf", lp = "lpf"}

-- Strudel effects the card has no way to play: accepted and left out, so
-- that Strudel code runs (dsl reports which ones were met).
M.IGNORED = {
  "hpf", "hp", "hcutoff", "bandf", "bpf", "bp", "resonance", "lpq", "hpq", "bpq", "lpenv", "hpenv",
  "lpattack", "lpdecay", "lpsustain", "lprelease", "ftype", "crush", "coarse", "shape", "distort",
  "room", "size", "roomsize", "rsize", "delay", "delaytime", "delayfeedback", "delayfb", "dry",
  "pan", "orbit", "vowel", "phaser", "phaserdepth", "tremolo", "speed", "begin", "end", "cut",
  "loop", "bank", "fm", "fmh", "fmi", "fmenv", "fmdecay", "fmsustain", "detune", "unison", "spread",
  "compressor", "vib", "vibrato", "vibmod", "penv", "pattack", "pdecay", "prelease", "lfo",
}
-- Drawing in Strudel's page: nothing to draw here, the pattern goes on.
M.VISUAL = {"_scope", "scope", "_pianoroll", "pianoroll", "_punchcard", "punchcard", "_spiral",
            "spiral", "_pitchwheel", "pitchwheel", "_spectrum", "spectrum", "color", "markcss"}
M.ignoredUsed = {}

local function control(name)
  local conv = CONVERT[name]
  return function(x)
    return P.fmap(P.reify(x), function(v)
      if type(v) == "table" then return union(v, {}) end
      local c, idx = conv(v)
      if c == nil then return nil end
      local t = {[name] = c}
      if idx and name == "s" then t.n = t.n or idx end
      return t
    end)
  end
end

for name in pairs(CONVERT) do
  local make = control(name)
  M[name] = make
  methods[name] = function(p, x) return P.appLeft(p, make(x), union) end
end
for alias, name in pairs(ALIAS) do
  M[alias] = M[name]
  methods[alias] = methods[name]
end
for _, name in ipairs(M.IGNORED) do
  methods[name] = function(p)
    M.ignoredUsed[name] = true
    return p
  end
end
for _, name in ipairs(M.VISUAL) do
  methods[name] = function(p) return p end
end

-- adsr("0.01:0.1:0.5:0.2"): attack, decay, sustain, release in one value.
local function adsr(v)
  if type(v) == "table" then return v end
  local a, d, s, r = tostring(v):match("^([%d%.]*):?([%d%.]*):?([%d%.]*):?([%d%.]*)$")
  return {attack = tonumber(a), decay = tonumber(d), sustain = tonumber(s), release = tonumber(r)}
end
function M.adsr(x) return P.fmap(P.reify(x), adsr) end
function methods.adsr(p, x) return P.appLeft(p, M.adsr(x), union) end

-- ------------------------------------------------------------------- sounds

-- Times of an attack, decay or release by the card's rate 0..15 (ms), from
-- sound/include/sndregs.h.
local RATE_MS = {1, 4, 8, 16, 24, 40, 60, 80, 100, 150, 250, 400, 600, 1000, 2000, 4000}

-- Seconds -> the nearest rate (on a log scale).
function M.rate(sec)
  local ms = math.max(1, sec * 1000)
  local best, bestErr = 0, math.huge
  for i, r in ipairs(RATE_MS) do
    local err = math.abs(math.log(ms / r))
    if err < bestErr then best, bestErr = i - 1, err end
  end
  return best
end

-- Sounds: a waveform, its envelope (seconds, sustain 0..1), a pitch when
-- no note is given, and for drums a pitch drop {ms, hz}.
M.SOUNDS = {
  triangle = {wave = "triangle"},
  square = {wave = "pulse", duty = 0.5},
  pulse = {wave = "pulse", duty = 0.25},
  sawtooth = {wave = "saw"},
  noise = {wave = "noise", hz = 4000},
  bd = {wave = "triangle", hz = 150, attack = 0, decay = 0.15, sustain = 0, release = 0.02,
        gain = 1.25, drop = {{8, 110}, {20, 75}, {40, 52}}},
  sd = {wave = "noise", hz = 3500, attack = 0, decay = 0.1, sustain = 0, release = 0.04},
  hh = {wave = "noise", hz = 12000, attack = 0, decay = 0.024, sustain = 0, release = 0.008, gain = 0.6},
  oh = {wave = "noise", hz = 12000, attack = 0, decay = 0.25, sustain = 0, release = 0.1, gain = 0.6},
  cp = {wave = "noise", hz = 2200, attack = 0, decay = 0.06, sustain = 0, release = 0.04},
  rim = {wave = "noise", hz = 6000, attack = 0, decay = 0.016, sustain = 0, release = 0.004},
  cr = {wave = "noise", hz = 9000, attack = 0, decay = 1, sustain = 0, release = 0.4, gain = 0.6},
  lt = {wave = "triangle", hz = 110, attack = 0, decay = 0.15, sustain = 0, release = 0.04,
        drop = {{20, 90}, {50, 75}}},
  mt = {wave = "triangle", hz = 160, attack = 0, decay = 0.15, sustain = 0, release = 0.04,
        drop = {{20, 130}, {50, 110}}},
  ht = {wave = "triangle", hz = 220, attack = 0, decay = 0.15, sustain = 0, release = 0.04,
        drop = {{20, 180}, {50, 150}}},
}
local S = M.SOUNDS
S.tri, S.sine, S.saw, S.white, S.pink, S.brown = S.triangle, S.triangle, S.sawtooth, S.noise, S.noise, S.noise
S.sq, S.sn, S.ch, S.hat, S.kick, S.snare, S.rs = S.square, S.sd, S.hh, S.hh, S.bd, S.sd, S.rim

-- Defaults of the melodic sounds (gain 0.8 as in Strudel).
local DEFAULT = {attack = 0.001, decay = 0.1, sustain = 0.7, release = 0.05, gain = 0.8, duty = 0.5}

-- What an event plays: {wave, duty, vol, attack, decay, sustain, release
-- (card units), hz, drop, voice}, or nil and why for a value it cannot
-- play.
function M.render(v)
  if type(v) ~= "table" then v = union(v, {}) end
  local name = v.s or "triangle"
  local snd = S[name]
  if not snd then return nil, "unknown sound: " .. tostring(name) end
  local function get(k)
    if v[k] ~= nil then return v[k] end
    if snd[k] ~= nil then return snd[k] end
    return DEFAULT[k]
  end
  local hz = v.freq
  local m = v.note
  if hz == nil and m == nil and v.n ~= nil and not snd.hz then m = v.n end
  if hz == nil and m ~= nil then hz = M.hz(m) end
  local drop
  if hz == nil then
    hz = snd.hz or M.hz(48)
    drop = snd.drop
  elseif snd.drop then
    -- A pitched drum: the drop keeps its shape from that pitch.
    drop = {}
    for i, d in ipairs(snd.drop) do drop[i] = {d[1], d[2] * hz / snd.hz} end
  end
  -- No filter on the card: a low-pass makes noise darker, that is all.
  if snd.wave == "noise" and tonumber(v.lpf) then hz = math.min(hz, tonumber(v.lpf)) end
  hz = math.max(8, math.min(7800, hz))
  local gain = (tonumber(get("gain")) or 0.8) * (tonumber(v.velocity) or 1) * (tonumber(v.postgain) or 1)
  local voice = tonumber(v.voice)
  -- Sustain as in Strudel: given an attack or a release only, the note
  -- holds at full level; given a decay, it decays to nothing.
  local sustain = tonumber(v.sustain)
  if sustain == nil and snd.sustain == nil and (v.attack ~= nil or v.decay ~= nil or v.release ~= nil) then
    sustain = v.decay ~= nil and 0 or 1
  end
  sustain = sustain or tonumber(get("sustain")) or 0
  if gain <= 0 then return nil end  -- muted: no voice taken
  local attack = M.rate(tonumber(get("attack")) or 0)
  local decay = M.rate(tonumber(get("decay")) or 0.1)
  local level = math.max(0, math.min(15, math.floor(sustain * 15 + 0.5)))
  return {
    wave = snd.wave,
    duty = math.max(0, math.min(255, math.floor((tonumber(get("duty")) or 0.5) * 256 + 0.5))),
    -- 4-bit volume, on a square-root curve: closer to how loud it sounds.
    vol = math.max(0, math.min(15, math.floor(15 * math.sqrt(math.max(0, gain)) + 0.5))),
    attack = attack,
    decay = decay,
    sustain = level,
    release = M.rate(tonumber(get("release")) or 0.05),
    releaseSec = tonumber(get("release")) or 0.05,
    -- Without sustain, silent after the attack and the decay (ms): the
    -- voice is free then, whatever the length of the note.
    silentAfter = level == 0 and RATE_MS[attack + 1] + RATE_MS[decay + 1] or nil,
    hz = hz,
    drop = drop,
    legato = tonumber(v.legato) or 1,
    voice = voice and math.max(1, math.min(4, math.floor(voice))) or nil,
  }
end

return M
