-- cycles.player: plays a pattern on the sound card. A little ahead of time
-- (LOOKAHEAD), it queries the pattern and hands each event to the card's
-- sequencer with synth.at(), which plays it on time even when this program
-- is busy drawing. Events go to the 4 voices in turn, the one free the
-- longest first.
local P = require "cycles.pattern"
local C = require "cycles.controls"

local M = {}
M.__index = M

local Q = 48           -- query boundaries: 1/48 of a cycle
local LOOKAHEAD = 250  -- ms
local VOICES = 4

local frac, tofrac, span = P.frac, P.tofrac, P.span

-- synth: termina.synth (or a stand-in with at, clear, off); millis: a clock.
function M.new(synth, millis)
  local self = setmetatable({synth = synth, millis = millis}, M)
  self.cps = frac(1, 2)
  self.busy, self.patch = {}, {}
  for v = 1, VOICES do self.busy[v] = 0 end
  self.next = 1
  self.played, self.dropped = 0, 0
  self:reset(millis())
  return self
end

-- Cycle 0 starts at ms t.
function M:reset(t)
  self.c0, self.t0 = P.ZERO, t
  self.pos = nil
end

-- ms at cycle c (a fraction).
function M:msAt(c)
  local d = c - self.c0
  local w, r = d.n // d.d, d.n % d.d
  local A = w * 1000 * self.cps.d
  local spc = 1000 * self.cps.d / self.cps.n
  return self.t0 + A // self.cps.n + math.floor((A % self.cps.n) / self.cps.n + r / d.d * spc + 0.5)
end

-- The cycle at ms t, rounded down to 1/Q.
function M:cycleAt(t)
  local e = t - self.t0
  local a, b = e // 1000, e % 1000
  local k = (a * self.cps.n * Q + (b * self.cps.n * Q) // 1000) // self.cps.d
  return self.c0 + frac(k, Q)
end

-- The current cycle as a number, for display.
function M:now()
  local e = self.millis() - self.t0
  return self.c0:num() + e / 1000 * self.cps.n / self.cps.d
end

-- Cycles per second (setcps). The current cycle carries on.
function M:setCps(cps)
  local f = tofrac(cps, 100)
  if f.n <= 0 then error("cps must be more than 0", 0) end
  if f == self.cps then return end
  local t = self.millis()
  local c = self:cycleAt(t)
  local tc = self:msAt(c)
  self.cps, self.c0, self.t0 = f, c, tc
end

function M:setPattern(p)
  local t = self.millis()
  if not self.pattern then self:reset(t) end
  self.synth.clear()
  self.patch = {}
  self.pattern = p
  self.pos = self:cycleAt(t)
  self.skipBefore = t
end

function M:hush()
  self.pattern = nil
  self.synth.clear()
  self.synth.off()
  self.patch = {}
end

-- Picks a voice for a note from t to free: a free voice that already has
-- this sound (no patch to send), else the next free one in turn, else the
-- one free the soonest.
function M:voiceFor(r, t, free, key)
  local v = r.voice
  if not v then
    local best, same
    for k = 0, VOICES - 1 do
      local c = (self.next + k - 1) % VOICES + 1
      if self.busy[c] <= t then
        if self.patch[c] == key then
          same = c
          break
        end
        best = best and self.busy[best] <= t and best or c
      elseif not best or (self.busy[best] > t and self.busy[c] < self.busy[best]) then
        best = c
      end
    end
    v = same or best
    self.next = v % VOICES + 1
  end
  self.busy[v] = free
  return v
end

local function patchKey(r)
  return r.wave .. r.duty .. "," .. r.vol .. "," .. r.attack .. r.decay .. "," .. r.sustain .. "," .. r.release
end

-- Plays one event at ms t, lasting ms.
function M:send(r, t, ms)
  local gate = math.max(1, math.min(65535, math.floor(ms * r.legato + 0.5)))
  local key = patchKey(r)
  local free = t + gate + math.floor(r.releaseSec * 1000)
  if r.silentAfter then free = math.min(free, t + r.silentAfter) end
  local v = self:voiceFor(r, t, free, key)
  local s = self.synth
  if self.patch[v] ~= key then
    s.at(t, "voice", v, {wave = r.wave, duty = r.duty, vol = r.vol, attack = r.attack, decay = r.decay,
                         sustain = r.sustain, release = r.release})
    self.patch[v] = key
  end
  if not s.at(t, "note", v, r.hz, gate) then self.dropped = self.dropped + 1 end
  if r.drop then
    for _, d in ipairs(r.drop) do
      if d[1] < gate then s.at(t + d[1], "freq", v, math.max(8, math.min(7800, d[2]))) end
    end
  end
  self.played = self.played + 1
end

-- Sends the events due within LOOKAHEAD. Returns nil, or an error raised
-- by the pattern (it is then stopped).
function M:tick()
  local p = self.pattern
  if not p then return end
  local now = self.millis()
  local target = self:cycleAt(now + LOOKAHEAD)
  if not self.pos then self.pos = self:cycleAt(now) end
  if target <= self.pos then return end
  local ok, haps = pcall(p.query, span(self.pos, target))
  self.pos = target
  if not ok then
    self.pattern = nil
    return tostring(haps)
  end
  local events = {}
  for _, h in ipairs(haps) do
    if P.onset(h) then events[#events + 1] = h end
  end
  table.sort(events, function(a, b) return a.whole.b < b.whole.b end)
  local skip = self.skipBefore
  self.skipBefore = nil
  local warn
  for _, h in ipairs(events) do
    local t = self:msAt(h.whole.b)
    if not skip or t >= skip then
      local r, why = C.render(h.value)
      if r then
        self:send(r, t, self:msAt(h.whole.e) - t)
      else
        warn = why
      end
    end
  end
  return nil, warn
end

return M
