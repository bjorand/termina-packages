-- cycles.player: plays a pattern on the sound card. Ahead of time, it
-- queries the pattern and hands each event to the card's sequencer with
-- synth.at(), which plays it on time even when this program is busy
-- drawing. Queries go by batches (BATCH ms of music each), so that their
-- fixed cost is paid a few times a second, not at every pass of the loop.
-- Events go to the 4 voices: a free voice that already has the sound, else
-- the next free one, else the one free the soonest.
local P = require "cycles.pattern"
local C = require "cycles.controls"

local M = {}
M.__index = M

local T = P.T
local Q = T // 48      -- query boundaries: 1/48 of a cycle (ticks)
local AHEAD = 500      -- ms of music queued ahead at most
local BATCH = 250      -- ms of music per query: queried when less is left
local START = 100      -- ms between play and the first note (the first query)
local VOICES = 4

local span = P.span

-- synth: termina.synth (or a stand-in with at, clear, off); millis: a clock.
function M.new(synth, millis)
  local self = setmetatable({synth = synth, millis = millis}, M)
  self.cpsN, self.cpsD = 1, 2
  self.busy, self.patch = {}, {}
  for v = 1, VOICES do self.busy[v] = 0 end
  self.next = 1
  self.played, self.dropped = 0, 0
  self:reset(millis())
  return self
end

-- Cycle 0 starts at ms t.
function M:reset(t)
  self.c0, self.t0 = 0, t
  self.pos = nil
end

-- "5/6": cycles per second, for display.
function M:cps()
  return self.cpsD == 1 and tostring(self.cpsN) or self.cpsN .. "/" .. self.cpsD
end

-- ms at tick c.
function M:msAt(c)
  local d = c - self.c0
  local w, r = d // T, d % T
  local A = w * 1000 * self.cpsD
  local spc = 1000 * self.cpsD / self.cpsN
  return self.t0 + A // self.cpsN + math.floor((A % self.cpsN) / self.cpsN + r / T * spc + 0.5)
end

-- The tick at ms t, rounded down to Q.
function M:cycleAt(t)
  local x = (t - self.t0) * self.cpsN
  local per = 1000 * self.cpsD        -- x / per cycles
  local whole, rest = x // per, x % per
  local ticks = whole * T + (rest * T) // per
  return self.c0 + ticks - ticks % Q
end

-- The current cycle as a number, for display.
function M:now()
  local e = self.millis() - self.t0
  return self.c0 / T + e / 1000 * self.cpsN / self.cpsD
end

-- Cycles per second (setcps). The current cycle carries on.
function M:setCps(cps)
  local n, d = P.ratio(cps, 60)
  if n <= 0 then error("cps must be more than 0", 0) end
  if n == self.cpsN and d == self.cpsD then return end
  self:rebase(self.millis())
  self.cpsN, self.cpsD = n, d
end

-- Moves the origin to a tick near t (exact on the Q grid), keeping the
-- numbers small.
function M:rebase(t)
  local c = self:cycleAt(t)
  self.t0, self.c0 = self:msAt(c), c
end

-- A new pattern. Started, it begins at cycle 0 a moment from now; while
-- one plays, the notes already queued finish and the new pattern goes on
-- from there (within AHEAD ms), without a gap or a late note.
function M:setPattern(p)
  if not self.pattern then
    self:reset(self.millis() + START)
    self.pos = 0
  end
  self.pattern = p
end

function M:hush()
  self.pattern = nil
  self.synth.clear()
  self.synth.off()
  self.patch = {}
end

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

-- Sends the events due soon, a batch at a time. Returns nil, or an error
-- raised by the pattern (it is then stopped), and a warning. ahead: how
-- much music to have queued (ms, AHEAD by default): more before a long
-- job, such as running new code.
function M:tick(ahead)
  local p = self.pattern
  if not p then return end
  ahead = ahead or AHEAD
  local now = self.millis()
  if now - self.t0 > 60000 then self:rebase(now) end
  if not self.pos then self.pos = self:cycleAt(now) end
  -- Fallen behind (the program was held up longer than the music queued):
  -- what was missed is skipped, not played late in a rush.
  if self:msAt(self.pos) < now then self.pos = self:cycleAt(now + START) end
  -- Enough queued already?
  if self:msAt(self.pos) > now + ahead - BATCH then return end
  local target = self:cycleAt(now + ahead)
  if target <= self.pos then return end
  local ok, haps = pcall(p.query, span(self.pos, target))
  self.pos = target
  if not ok then
    self.pattern = nil
    return tostring(haps)
  end
  local events = {}
  for _, h in ipairs(haps) do
    if h.whole and h.whole.b == h.part.b then events[#events + 1] = h end
  end
  table.sort(events, function(a, b) return a.whole.b < b.whole.b end)
  local warn
  for _, h in ipairs(events) do
    local t = self:msAt(h.whole.b)
    local r, why = C.render(h.value)
    if r then
      self:send(r, t, self:msAt(h.whole.e) - t)
    elseif why then
      warn = why
    end
  end
  return nil, warn
end

return M
