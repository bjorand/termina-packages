-- cycles.pattern: the pattern engine, a Lua port of the core of Strudel and
-- TidalCycles. A pattern is a function of time: query(span) returns the
-- events ("haps") that happen during that span of cycles. A hap has a whole
-- (the span of the full event, nil for continuous signals), a part (the
-- piece of it inside the query) and a value.
--
-- Time is an integer count of ticks, T per cycle. T = 20160 = 2^6*3^2*5*7:
-- halves down to 64ths, thirds, fifths, sevenths and ninths of a cycle are
-- exact, anything else is rounded to the tick (50 us at 1 cycle/s). Plain
-- integers keep the ESP32 fast: no table, no gcd per operation. With 32-bit
-- numbers, time goes up to about 100000 cycles.
local M = {}

local T = 20160
M.T = T

local function gcd(a, b)
  if a < 0 then a = -a end
  if b < 0 then b = -b end
  while b ~= 0 do a, b = b, a % b end
  return a
end
M.gcd = gcd

-- t * n / d rounded down, without computing t * n (it could overflow).
local function scale(t, n, d)
  if d == 1 then return t * n end
  return (t // d) * n + ((t % d) * n) // d
end
M.scale = scale

-- A number as a ratio n/d (d > 0): integers exactly, others by continued
-- fractions (0.25 -> 1/4, 0.1 -> 1/10), denominator up to maxDen.
local function ratio(x, maxDen)
  if type(x) ~= "number" then
    local v = tonumber(x)
    if not v then error("not a number: " .. tostring(x), 3) end
    x = v
  end
  local i = math.tointeger(x)
  if i then return i, 1 end
  maxDen = maxDen or 1000
  local neg = x < 0
  if neg then x = -x end
  local h0, h1, k0, k1 = 0, 1, 1, 0
  local y = x
  for _ = 1, 24 do
    local a = math.floor(y)
    local h2, k2 = a * h1 + h0, a * k1 + k0
    if k2 > maxDen then break end
    h0, h1, k0, k1 = h1, h2, k1, k2
    if math.abs(x - h1 / k1) <= 1e-5 * math.max(1, x) then break end
    local r = y - a
    if r < 1e-7 then break end
    y = 1 / r
  end
  if k1 == 0 then h1, k1 = math.floor(x + 0.5), 1 end
  local g = gcd(h1, k1)
  if g > 1 then h1, k1 = h1 // g, k1 // g end
  return neg and -h1 or h1, k1
end
M.ratio = ratio

-- Cycles (a number, or n/d) to ticks.
function M.frac(n, d) return scale(n, T, d or 1) end
function M.time(x)
  local i = math.tointeger(x)
  if i then return i * T end
  x = tonumber(x) or error("not a number: " .. tostring(x), 2)
  local w = math.floor(x)
  return w * T + math.floor((x - w) * T + 0.5)
end

-- Ticks as "n/d" cycles ("1/3", "2", "-1/4"), for tests and messages.
function M.show(t)
  local g = gcd(t, T)
  if g == T then return tostring(t // T) end
  return (t // g) .. "/" .. (T // g)
end

local function sam(t) return t - t % T end
local function cyc(t) return t // T end
M.sam, M.cyc = sam, cyc

-- ------------------------------------------------------------------- spans

local function span(b, e) return {b = b, e = e} end

-- Splits a span at cycle boundaries.
local function spanCycles(s)
  local b, e = s.b, s.e
  if b == e then return {s} end
  local out = {}
  while b < e do
    local nxt = sam(b) + T
    if e <= nxt then
      out[#out + 1] = span(b, e)
      break
    end
    out[#out + 1] = span(b, nxt)
    b = nxt
  end
  return out
end

local function sect(x, y)
  local b = x.b > y.b and x.b or y.b
  local e = x.e < y.e and x.e or y.e
  if b > e then return nil end
  if b == e then
    -- A point does not meet a span at its end.
    if b == x.e and x.b < x.e then return nil end
    if b == y.e and y.b < y.e then return nil end
  end
  return span(b, e)
end

M.span, M.spanCycles, M.sect = span, spanCycles, sect

-- An event starts in this part (and is not the tail of an earlier one).
function M.onset(h) return h.whole ~= nil and h.whole.b == h.part.b end

-- ---------------------------------------------------------------- patterns

-- Methods, callable both ways: p:fast(2) (Lua) and p.fast(2) (Strudel).
local methods = {}
local Pmt = {}
Pmt.__index = function(p, k)
  local m = methods[k]
  if m == nil then return nil end
  return function(a, ...)
    if rawequal(a, p) then return m(p, ...) end
    return m(p, a, ...)
  end
end
Pmt.__tostring = function() return "pattern" end

local function pattern(q) return setmetatable({query = q}, Pmt) end
local function isPattern(x) return getmetatable(x) == Pmt end

M.pattern, M.isPattern, M.methods = pattern, isPattern, methods

local function hap(whole, part, value) return {whole = whole, part = part, value = value} end

local silence = pattern(function() return {} end)
silence._silent = true
M.silence = silence

-- One pattern per value: patterns never change, so "E" or "-" written a
-- hundred times in a song is one object, not a hundred (memory). A pure
-- pattern is marked (_pure, _v): sequences and controls use its value
-- without querying it.
local pureCache = {
  string = setmetatable({}, {__mode = "v"}),
  integer = setmetatable({}, {__mode = "v"}),
  float = setmetatable({}, {__mode = "v"}),
  boolean = setmetatable({}, {__mode = "v"}),
}

local function pure(v)
  local kind = math.type(v) or type(v)
  local cache = v == v and pureCache[kind] or nil  -- NaN is no table key
  local p = cache and cache[v]
  if p then return p end
  p = pattern(function(s)
    local out = {}
    for _, c in ipairs(spanCycles(s)) do
      local b = sam(c.b)
      out[#out + 1] = hap(span(b, b + T), c, v)
    end
    return out
  end)
  p._pure, p._v = true, v
  if cache then cache[v] = p end
  return p
end
M.pure = pure

-- A continuous pattern: f(t) for t the start of the query, no whole.
local function signal(f)
  return pattern(function(s) return {hap(nil, s, f(s.b))} end)
end
M.signal = signal

local function splitQueries(p)
  return pattern(function(s)
    local cs = spanCycles(s)
    if #cs == 1 then return p.query(s) end
    local out = {}
    for _, c in ipairs(cs) do
      for _, h in ipairs(p.query(c)) do out[#out + 1] = h end
    end
    return out
  end)
end

-- Query times through qf, event times back through hf.
local function withTime(p, qf, hf)
  return pattern(function(s)
    local out = {}
    for i, h in ipairs(p.query(span(qf(s.b), qf(s.e)))) do
      local w = h.whole
      out[i] = hap(w and span(hf(w.b), hf(w.e)), span(hf(h.part.b), hf(h.part.e)), h.value)
    end
    return out
  end)
end

-- The same events, moved by d ticks.
local function shift(p, d)
  if d == 0 then return p end
  return pattern(function(s)
    local out = {}
    for i, h in ipairs(p.query(span(s.b - d, s.e - d))) do
      local w = h.whole
      out[i] = hap(w and span(w.b + d, w.e + d), span(h.part.b + d, h.part.e + d), h.value)
    end
    return out
  end)
end

local function fmapOf(p, f)
  local q = pattern(function(s)
    local out = {}
    for _, h in ipairs(p.query(s)) do
      local v = f(h.value)
      if v ~= nil then out[#out + 1] = hap(h.whole, h.part, v) end
    end
    return out
  end)
  q._fsrc, q._ff = p, f
  return q
end

-- The values changed by f (nil leaves the event out). fmap of an fmap is
-- one level, not two: one event made per query instead of one per level.
local function fmap(p, f)
  if p._pure then
    local v = f(p._v)
    if v == nil then return silence end
    return pure(v)
  end
  if p._fsrc then
    local g = p._ff
    return fmapOf(p._fsrc, function(v)
      local x = g(v)
      if x ~= nil then return f(x) end
    end)
  end
  return fmapOf(p, f)
end
M.fmap = fmap

local function filterHaps(p, keep)
  return pattern(function(s)
    local out = {}
    for _, h in ipairs(p.query(s)) do
      if keep(h) then out[#out + 1] = h end
    end
    return out
  end)
end

-- The structure of p, with values f(p's value, other's value) taken from
-- other where each event of p starts. A constant other is not queried.
local function appLeft(p, other, f)
  if other._pure then
    local v = other._v
    return fmap(p, function(x) return f(x, v) end)
  end
  return pattern(function(s)
    local out = {}
    for _, hl in ipairs(p.query(s)) do
      for _, hr in ipairs(other.query(hl.whole or hl.part)) do
        local part = sect(hl.part, hr.part)
        if part then
          local v = f(hl.value, hr.value)
          if v ~= nil then out[#out + 1] = hap(hl.whole, part, v) end
        end
      end
    end
    return out
  end)
end
M.appLeft = appLeft

-- A pattern of patterns flattened: the events of the inner patterns, while
-- each outer event lasts.
local function innerJoin(pp)
  return pattern(function(s)
    local out = {}
    for _, ho in ipairs(pp.query(s)) do
      if ho.whole then
        for _, hi in ipairs(ho.value.query(ho.part)) do out[#out + 1] = hi end
      end
    end
    return out
  end)
end
M.innerJoin = innerJoin

-- ------------------------------------------------------------------ values

-- Anything to a pattern: patterns as they are, strings as mini-notation
-- (M.parse, set by cycles.mini), lists as sequences, others as constants.
local function reify(x)
  if isPattern(x) then return x end
  local t = type(x)
  if t == "string" then return M.parse(x) end
  if t == "table" and getmetatable(x) == nil and #x > 0 then return M.fastcat(x) end
  return pure(x)
end
M.reify = reify

-- Wraps fn(p, arg, ...) so that arg may be a pattern too: "<1 2>". A
-- constant pattern is used as its value.
local function patternify(fn)
  return function(p, arg, ...)
    if type(arg) == "string" then arg = reify(arg) end
    if isPattern(arg) then
      if arg._pure then return fn(p, arg._v, ...) end
      local n, rest = select("#", ...), {...}
      return innerJoin(fmap(arg, function(v) return fn(p, v, table.unpack(rest, 1, n)) end))
    end
    return fn(p, arg, ...)
  end
end
M.patternify = patternify

local function list(...)
  local t = {...}
  if #t == 1 and type(t[1]) == "table" and getmetatable(t[1]) == nil then t = t[1] end
  local out = {}
  for i, x in ipairs(t) do out[i] = reify(x) end
  return out
end

-- ---------------------------------------------------------------- combining

local function stack(pats)
  local live = {}
  for _, p in ipairs(pats) do
    if not p._silent then live[#live + 1] = p end
  end
  if #live == 0 then return silence end
  if #live == 1 then return live[1] end
  return pattern(function(s)
    local out = {}
    for _, p in ipairs(live) do
      for _, h in ipairs(p.query(s)) do out[#out + 1] = h end
    end
    return out
  end)
end

-- One pattern per cycle, in turn: cycle c plays cycle c // n of pattern
-- c % n + 1.
local function slowcat(pats)
  local n = #pats
  if n == 0 then return silence end
  if n == 1 then return pats[1] end
  return splitQueries(pattern(function(s)
    local c = cyc(s.b)
    local p = pats[c % n + 1]
    if p._silent then return {} end
    local off = (c - c // n) * T
    local out = {}
    for i, h in ipairs(p.query(span(s.b - off, s.e - off))) do
      local w = h.whole
      out[i] = hap(w and span(w.b + off, w.e + off), span(h.part.b + off, h.part.e + off), h.value)
    end
    return out
  end))
end

-- Faster by n/d.
local function fastND(p, n, d)
  if p._silent then return p end
  if n == 0 then return silence end
  if n < 0 then return methods.rev(fastND(p, -n, d)) end
  if n == d then return p end
  return withTime(p, function(t) return scale(t, n, d) end, function(t) return scale(t, d, n) end)
end

local function _fast(p, f) return fastND(p, ratio(f)) end

local function _slow(p, f)
  local n, d = ratio(f)
  if n == 0 then return silence end
  if n < 0 then n, d = -n, -d end
  return fastND(p, d, n)
end

local function _early(p, t) return shift(p, -M.time(t)) end
local function _late(p, t) return shift(p, M.time(t)) end

-- n patterns in one cycle, each in its step: step i of cycle c plays cycle
-- c of pattern i. Constant steps (most of them: notes, rests) are made
-- right here, without a query.
local function fastcat(pats)
  local n = #pats
  if n == 0 then return silence end
  if n == 1 then return pats[1] end
  local Tn = T % n
  return pattern(function(s)
    local out = {}
    -- Steps k (all cycles together) that the query meets.
    -- (one more at the end: with n not dividing T, a step boundary is
    -- rounded, and sect() leaves out what is not met).
    local k0 = scale(s.b, n, T)
    local k1 = scale(s.e, n, T) + 1
    for k = k0, k1 do
      local i = k % n + 1
      local p = pats[i]
      if not p._silent then
        local sb, se = scale(k, T, n), scale(k + 1, T, n)
        local q = span(sb, se)
        local part = sect(s, q)
        if part and (part.b < part.e or s.b == s.e) then
          if p._pure then
            out[#out + 1] = hap(q, part, p._v)
          else
            -- Inner time t' = c*T + (t - sb)*n - r, r = k*T mod n.
            local cT = (k // n) * T
            local r = ((k % n) * Tn) % n
            local function back(t) return sb + (t - cT + r) // n end
            for _, h in ipairs(p.query(span(cT + (part.b - sb) * n - r, cT + (part.e - sb) * n - r))) do
              local w = h.whole
              out[#out + 1] = hap(w and span(back(w.b), back(w.e)), span(back(h.part.b), back(h.part.e)), h.value)
            end
          end
        end
      end
    end
    return out
  end)
end

-- Squeezes each cycle of p into its first n/d... d/n of it (factor n/d >=
-- 1), silence after.
local function _fastGap(p, n, d)
  return splitQueries(pattern(function(s)
    local cycle = sam(s.b)
    local bpos = math.min(scale(s.b - cycle, n, d), T)
    local epos = math.min(scale(s.e - cycle, n, d), T)
    if bpos >= T then return {} end
    local out = {}
    for _, h in ipairs(p.query(span(cycle + bpos, cycle + epos))) do
      local pb, pe = h.part.b, h.part.e
      local hc = sam(pb)
      local nb = hc + math.min(scale(pb - hc, d, n), T)
      local ne = hc + math.min(scale(pe - hc, d, n), T)
      local whole
      if h.whole then whole = span(nb - scale(pb - h.whole.b, d, n), ne + scale(h.whole.e - pe, d, n)) end
      out[#out + 1] = hap(whole, span(nb, ne), h.value)
    end
    return out
  end))
end

-- Each cycle of p squeezed into ticks [b, e) of the cycle.
local function compress(p, b, e)
  if b >= e or b < 0 or e > T then return silence end
  if b == 0 and e == T then return p end
  local g = gcd(T, e - b)
  return shift(_fastGap(p, T // g, (e - b) // g), b)
end

-- Sequence of {weight, pattern}: each takes its share of the cycle.
local function timecat(items)
  local even = true
  for _, it in ipairs(items) do
    if it[1] ~= 1 then even = false end
  end
  if even then
    local pats = {}
    for i, it in ipairs(items) do pats[i] = it[2] end
    return fastcat(pats)
  end
  -- Integer weights (1.5 counts as 1500 thousandths).
  local ints, scaleBy = {}, 1
  for _, it in ipairs(items) do
    if not math.tointeger(it[1]) then scaleBy = 1000 end
  end
  local total = 0
  for i, it in ipairs(items) do
    ints[i] = math.floor(it[1] * scaleBy + 0.5)
    total = total + ints[i]
  end
  if total <= 0 then return silence end
  local pats, pos = {}, 0
  for i, it in ipairs(items) do
    if ints[i] > 0 then
      pats[#pats + 1] = compress(it[2], scale(pos, T, total), scale(pos + ints[i], T, total))
      pos = pos + ints[i]
    end
  end
  return stack(pats)
end

M.stack, M.slowcat, M.fastcat, M.timecat = stack, slowcat, fastcat, timecat

-- --------------------------------------------------------------- randomness

local MASK = 0x7fffffff
local function hash(x)
  x = x & MASK
  x = x ~ ((x << 13) & MASK)
  x = x ~ (x >> 17)
  x = x ~ ((x << 5) & MASK)
  return x & MASK
end

-- A random number in [0, 1) that depends only on the time t (ticks) and
-- the seed: the same pattern plays the same "random" notes every time.
local function randAt(t, seed)
  local h = hash(t * 31337 + (seed or 0) * 104729 + 1013)
  h = hash(h + 1540483477)
  return (h % 1000003) / 1000003
end
M.randAt = randAt

local function _degradeBy(p, amount, seed, keepBelow)
  amount = tonumber(amount) or 0.5
  return filterHaps(p, function(h)
    local r = randAt(h.whole and h.whole.b or h.part.b, seed)
    if keepBelow then return r < amount end
    return r >= amount
  end)
end
M.degradeBy = _degradeBy

-- One of pats per cycle, at random.
function M.randcat(pats, seed)
  local n = #pats
  if n == 1 then return pats[1] end
  return splitQueries(pattern(function(s)
    local i = math.floor(randAt(sam(s.b), (seed or 0) + 7) * n) % n + 1
    return pats[i].query(s)
  end))
end

-- --------------------------------------------------------------- euclidean

-- Bjorklund's algorithm: k onsets spread as evenly as possible over n steps
-- (3, 8 -> x..x..x.), rotated left by r steps.
local function bjorklund(k, n, r)
  local out = {}
  if n <= 0 then return out end
  if k >= n or k <= 0 then
    for i = 1, n do out[i] = k > 0 end
    return out
  end
  local a, b = {}, {}
  for i = 1, k do a[i] = {true} end
  for i = 1, n - k do b[i] = {false} end
  while #b > 1 do
    local m = math.min(#a, #b)
    local na, nb = {}, {}
    for i = 1, m do
      local s = {}
      for _, v in ipairs(a[i]) do s[#s + 1] = v end
      for _, v in ipairs(b[i]) do s[#s + 1] = v end
      na[i] = s
    end
    for i = m + 1, #a do nb[#nb + 1] = a[i] end
    for i = m + 1, #b do nb[#nb + 1] = b[i] end
    a, b = na, nb
  end
  local flat = {}
  for _, s in ipairs(a) do for _, v in ipairs(s) do flat[#flat + 1] = v end end
  for _, s in ipairs(b) do for _, v in ipairs(s) do flat[#flat + 1] = v end end
  r = (r or 0) % n
  for i = 1, n do out[i] = flat[(i - 1 + r) % n + 1] end
  return out
end
M.bjorklund = bjorklund

local function truthy(v)
  if v == true then return true end
  if type(v) == "number" then return v ~= 0 end
  if type(v) == "string" then return v ~= "f" and v ~= "false" and v ~= "0" and v ~= "~" end
  return false
end

local function struct(p, b)
  return appLeft(reify(b), p, function(bv, v) if truthy(bv) then return v end end)
end

local function euclid(p, k, n, r)
  k, n, r = math.tointeger(tonumber(k)), math.tointeger(tonumber(n)), math.tointeger(tonumber(r or 0))
  if not (k and n and r) then error("euclid: whole numbers expected", 2) end
  local pats = {}
  for i, on in ipairs(bjorklund(k, n, r)) do pats[i] = on and pure(true) or silence end
  return struct(p, fastcat(pats))
end

-- ------------------------------------------------------------------ methods

local function num(v)
  if type(v) == "number" then return v end
  return M.toNumber and M.toNumber(v) or tonumber(v)
end

function methods.fast(p, f) return patternify(_fast)(p, f) end
function methods.slow(p, f) return patternify(_slow)(p, f) end
function methods.early(p, t) return patternify(_early)(p, t) end
function methods.late(p, t) return patternify(_late)(p, t) end
methods.density, methods.sparsity = methods.fast, methods.slow

function methods.rev(p)
  return splitQueries(pattern(function(s)
    local cycle = sam(s.b)
    local nxt = cycle + T
    local function reflect(sp) return span(cycle + (nxt - sp.e), cycle + (nxt - sp.b)) end
    local out = {}
    for i, h in ipairs(p.query(reflect(s))) do
      out[i] = hap(h.whole and reflect(h.whole), reflect(h.part), h.value)
    end
    return out
  end))
end

-- f applied on the first of every n cycles (firstOf), or the last (lastOf).
local function ofCycles(p, n, f, last)
  n = math.tointeger(num(n))
  if not n or n < 1 then error("every: a count of 1 or more", 3) end
  local q = f(p)
  return splitQueries(pattern(function(s)
    local c = cyc(s.b) % n
    if c == (last and n - 1 or 0) then return q.query(s) end
    return p.query(s)
  end))
end
function methods.every(p, n, f) return ofCycles(p, n, f, false) end
methods.firstOf = methods.every
function methods.lastOf(p, n, f) return ofCycles(p, n, f, true) end

function methods.palindrome(p) return ofCycles(p, 2, methods.rev, true) end

-- Starts each cycle 1/n later in the pattern than the one before.
function methods.iter(p, n)
  n = math.tointeger(num(n))
  return splitQueries(pattern(function(s)
    return shift(p, -scale(cyc(s.b) % n, T, n)).query(s)
  end))
end

-- Repeats each event n times within its own length.
function methods.ply(p, n)
  n = math.tointeger(num(n))
  if not n or n < 1 then return p end
  return pattern(function(s)
    local out = {}
    for _, h in ipairs(p.query(s)) do
      if h.whole then
        local len = h.whole.e - h.whole.b
        for i = 0, n - 1 do
          local w = span(h.whole.b + scale(len, i, n), h.whole.b + scale(len, i + 1, n))
          local part = sect(w, h.part)
          if part and (part.b < part.e or w.b == w.e) then out[#out + 1] = hap(w, part, h.value) end
        end
      end
    end
    return out
  end)
end

function methods.struct(p, b) return struct(p, b) end
function methods.euclid(p, k, n, r) return euclid(p, k, n, r) end
function methods.euclidRot(p, k, n, r) return euclid(p, k, n, r) end

-- Samples a continuous pattern n times per cycle.
function methods.segment(p, n)
  return appLeft(_fast(pure(true), n), p, function(_, v) return v end)
end

function methods.degradeBy(p, amount) return _degradeBy(p, amount, 0) end
function methods.degrade(p) return _degradeBy(p, 0.5, 0) end
function methods.undegradeBy(p, amount) return _degradeBy(p, amount, 0, true) end

function methods.sometimesBy(p, amount, f)
  amount = num(amount)
  return stack({_degradeBy(p, amount, 1), f(_degradeBy(p, amount, 1, true))})
end
for name, amount in pairs({sometimes = 0.5, often = 0.75, rarely = 0.25, almostNever = 0.1,
                           almostAlways = 0.9}) do
  methods[name] = function(p, f) return methods.sometimesBy(p, amount, f) end
end

function methods.superimpose(p, f) return stack({p, f(p)}) end
function methods.off(p, t, f) return stack({p, f(_late(p, t))}) end
function methods.layer(p, ...)
  local out = {}
  for i, f in ipairs({...}) do out[i] = f(p) end
  return stack(out)
end
function methods.stack(p, ...)
  local pats = list(...)
  table.insert(pats, 1, p)
  return stack(pats)
end
function methods.cat(p, ...)
  local pats = list(...)
  table.insert(pats, 1, p)
  return slowcat(pats)
end
function methods.seq(p, ...)
  local pats = list(...)
  table.insert(pats, 1, p)
  return fastcat(pats)
end
-- compress(p, b, e): b and e in cycles (0..1).
function methods.compress(p, b, e) return compress(p, M.time(b), M.time(e)) end
function methods.fmap(p, f) return fmap(p, f) end
function methods.filter(p, f) return filterHaps(p, function(h) return f(h.value) end) end

-- Values within [lo, hi] instead of [0, 1].
function methods.range(p, lo, hi)
  return fmap(p, function(v) return num(v) * (hi - lo) + lo end)
end

-- query(b, e): the events from cycle b to cycle e (numbers).
function methods.query(p, b, e) return p.query(span(M.time(b), M.time(e))) end

-- Arithmetic on values. On control tables (note, n...) the numbers add key
-- by key; a plain number goes to the note (or n).
local function copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end
local function numop(f)
  local function apply(a, b)
    if type(a) == "table" then
      local r = copy(a)
      if type(b) == "table" then
        for k, v in pairs(b) do
          if type(r[k]) == "number" and type(v) == "number" then r[k] = f(r[k], v) else r[k] = v end
        end
      else
        local k = r.note ~= nil and "note" or r.n ~= nil and "n" or nil
        if k then r[k] = f(num(r[k]), num(b)) end
      end
      return r
    end
    if type(b) == "table" then return apply(b, a) end
    return f(num(a), num(b))
  end
  return function(p, x) return appLeft(p, reify(x), apply) end
end
methods.add = numop(function(a, b) return a + b end)
methods.sub = numop(function(a, b) return a - b end)
methods.mul = numop(function(a, b) return a * b end)
methods.div = numop(function(a, b) return a / b end)

-- ------------------------------------------------------------- free functions

function M.fast(f, p) return methods.fast(reify(p), f) end
function M.slow(f, p) return methods.slow(reify(p), f) end
function M.cat(...) return slowcat(list(...)) end
function M.seq(...) return fastcat(list(...)) end
function M.stack(...) return stack(list(...)) end
-- timeCat({3, "c e g"}, {1, "b"})
function M.timeCat(...)
  local items = {}
  for i, it in ipairs({...}) do items[i] = {it[1], reify(it[2])} end
  return timecat(items)
end
function M.rev(p) return methods.rev(reify(p)) end

-- arrange({2, a}, {8, b}): a for 2 cycles, then b for 8, then again. Each
-- section goes on from where it was the time before, like in Strudel.
function M.arrange(...)
  local secs, total = {}, 0
  for _, s in ipairs({...}) do
    local n = math.tointeger(tonumber(s[1]))
    if not n or n < 1 then error("arrange: {cycles, pattern} expected", 2) end
    secs[#secs + 1] = {n = n, start = total, pat = reify(s[2])}
    total = total + n
  end
  if total == 0 then return silence end
  return splitQueries(pattern(function(s)
    local c = cyc(s.b)
    local loop, pos = c // total, c % total
    for _, sec in ipairs(secs) do
      if pos < sec.start + sec.n then
        local d = (loop * sec.n + pos - sec.start - c) * T
        local out = {}
        for i, h in ipairs(sec.pat.query(span(s.b + d, s.e + d))) do
          local w = h.whole
          out[i] = hap(w and span(w.b - d, w.e - d), span(h.part.b - d, h.part.e - d), h.value)
        end
        return out
      end
    end
    return {}
  end))
end

local TAU = 2 * math.pi
local function pos(t) return (t % T) / T end
M.sine = signal(function(t) return (math.sin(TAU * pos(t)) + 1) / 2 end)
M.cosine = shift(M.sine, -T // 4)
M.saw = signal(function(t) return pos(t) end)
M.isaw = signal(function(t) return 1 - pos(t) end)
M.tri = signal(function(t)
  local x = pos(t)
  return x < 0.5 and 2 * x or 2 - 2 * x
end)
M.square = signal(function(t) return pos(t) < 0.5 and 0 or 1 end)
M.rand = signal(function(t) return randAt(t, 99) end)
function M.irand(n) return fmap(M.rand, function(v) return math.floor(v * n) end) end
function M.run(n) -- 0 1 2 .. n-1
  local pats = {}
  for i = 0, n - 1 do pats[#pats + 1] = pure(i) end
  return fastcat(pats)
end

return M
