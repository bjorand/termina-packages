-- cycles.pattern: the pattern engine, a Lua port of the core of Strudel and
-- TidalCycles. A pattern is a function of time: query(span) returns the
-- events ("haps") that happen during that span of cycles. A hap has a whole
-- (the span of the full event, nil for continuous signals), a part (the
-- piece of it inside the query) and a value.
--
-- Time is exact: fractions of two integers, so that 1/3 + 2/3 is 1. Numbers
-- are 32-bit on the machine, so the arithmetic below avoids multiplying two
-- large numerators (a cycle count times a denominator is fine, two of them
-- are not).
local M = {}

-- ---------------------------------------------------------------- fractions

local F = {}
F.__index = F

local function gcd(a, b)
  if a < 0 then a = -a end
  if b < 0 then b = -b end
  while b ~= 0 do a, b = b, a % b end
  return a
end

local function raw(n, d) return setmetatable({n = n, d = d}, F) end

local function frac(n, d)
  d = d or 1
  if d == 0 then error("division by zero in a time value", 2) end
  if d < 0 then n, d = -n, -d end
  local g = gcd(n, d)
  if g > 1 then n, d = n // g, d // g end
  return raw(n, d)
end

-- Turns a Lua number into a fraction: integers exactly, other numbers by
-- continued fractions (0.25 -> 1/4, 0.1 -> 1/10), denominator up to maxDen.
local function tofrac(x, maxDen)
  if getmetatable(x) == F then return x end
  if type(x) ~= "number" then
    local v = tonumber(x)
    if not v then error("not a number: " .. tostring(x), 3) end
    x = v
  end
  local i = math.tointeger(x)
  if i then return raw(i, 1) end
  maxDen = maxDen or 10000
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
  return frac(neg and -h1 or h1, k1)
end

local function add(a, b)
  if a.d == b.d then return frac(a.n + b.n, a.d) end
  local g = gcd(a.d, b.d)
  return frac(a.n * (b.d // g) + b.n * (a.d // g), a.d // g * b.d)
end

local function mul(a, b)
  local g1, g2 = gcd(a.n, b.d), gcd(b.n, a.d)
  if g1 == 0 then g1 = 1 end
  if g2 == 0 then g2 = 1 end
  return frac((a.n // g1) * (b.n // g2), (a.d // g2) * (b.d // g1))
end

local function cmp(a, b)
  local fa, fb = a.n // a.d, b.n // b.d
  if fa ~= fb then return fa < fb and -1 or 1 end
  local ra, rb = (a.n % a.d) * b.d, (b.n % b.d) * a.d
  if ra == rb then return 0 end
  return ra < rb and -1 or 1
end

F.__add = function(a, b) return add(tofrac(a), tofrac(b)) end
F.__sub = function(a, b)
  b = tofrac(b)
  return add(tofrac(a), raw(-b.n, b.d))
end
F.__mul = function(a, b) return mul(tofrac(a), tofrac(b)) end
F.__div = function(a, b)
  a, b = tofrac(a), tofrac(b)
  if b.n == 0 then error("division by zero in a time value", 2) end
  if b.n < 0 then return mul(a, raw(-b.d, -b.n)) end
  return mul(a, raw(b.d, b.n))
end
F.__unm = function(a) return raw(-a.n, a.d) end
F.__eq = function(a, b) return a.n == b.n and a.d == b.d end
F.__lt = function(a, b) return cmp(tofrac(a), tofrac(b)) < 0 end
F.__le = function(a, b) return cmp(tofrac(a), tofrac(b)) <= 0 end
F.__tostring = function(a) return a.d == 1 and tostring(a.n) or a.n .. "/" .. a.d end

function F.sam(a) return raw(a.n // a.d, 1) end              -- start of its cycle
function F.cyc(a) return a.n // a.d end                       -- cycle number
function F.pos(a) return raw(a.n % a.d, a.d) end              -- position in its cycle
function F.num(a) return a.n / a.d end

local ZERO, ONE = raw(0, 1), raw(1, 1)
local function fmin(a, b) return cmp(a, b) <= 0 and a or b end
local function fmax(a, b) return cmp(a, b) >= 0 and a or b end

M.frac, M.tofrac, M.isfrac = frac, tofrac, function(x) return getmetatable(x) == F end
M.ZERO, M.ONE = ZERO, ONE

-- ------------------------------------------------------------------- spans

local function span(b, e) return {b = b, e = e} end

-- Splits a span at cycle boundaries.
local function spanCycles(s)
  local b, e = s.b, s.e
  if b == e then return {s} end
  local out = {}
  while b < e do
    local nxt = raw(b.n // b.d + 1, 1)
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
  local b, e = fmax(x.b, y.b), fmin(x.e, y.e)
  local c = cmp(b, e)
  if c > 0 then return nil end
  if c == 0 then
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
M.silence = silence

local function pure(v)
  return pattern(function(s)
    local out = {}
    for _, c in ipairs(spanCycles(s)) do
      local b = raw(c.b.n // c.b.d, 1)
      out[#out + 1] = hap(span(b, b + ONE), c, v)
    end
    return out
  end)
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

local function withTime(p, qf, hf)
  return pattern(function(s)
    local out = {}
    for i, h in ipairs(p.query(span(qf(s.b), qf(s.e)))) do
      out[i] = hap(h.whole and span(hf(h.whole.b), hf(h.whole.e)), span(hf(h.part.b), hf(h.part.e)), h.value)
    end
    return out
  end)
end

local function fmap(p, f)
  return pattern(function(s)
    local out = {}
    for _, h in ipairs(p.query(s)) do
      local v = f(h.value)
      if v ~= nil then out[#out + 1] = hap(h.whole, h.part, v) end
    end
    return out
  end)
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
-- other where each event of p starts.
local function appLeft(p, other, f)
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

-- Wraps fn(p, arg, ...) so that arg may be a pattern too: "<1 2>".
local function patternify(fn)
  return function(p, arg, ...)
    if isPattern(arg) or type(arg) == "string" then
      local n, rest = select("#", ...), {...}
      return innerJoin(fmap(reify(arg), function(v) return fn(p, v, table.unpack(rest, 1, n)) end))
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
  if #pats == 1 then return pats[1] end
  return pattern(function(s)
    local out = {}
    for _, p in ipairs(pats) do
      for _, h in ipairs(p.query(s)) do out[#out + 1] = h end
    end
    return out
  end)
end

-- One pattern per cycle, in turn.
local function slowcat(pats)
  local n = #pats
  if n == 0 then return silence end
  if n == 1 then return pats[1] end
  return splitQueries(pattern(function(s)
    local c = s.b.n // s.b.d
    local off = raw(c - c // n, 1)
    local out = {}
    for i, h in ipairs(pats[c % n + 1].query(span(s.b - off, s.e - off))) do
      out[i] = hap(h.whole and span(h.whole.b + off, h.whole.e + off), span(h.part.b + off, h.part.e + off),
                   h.value)
    end
    return out
  end))
end

local function _fast(p, f)
  f = tofrac(f)
  if f.n == 0 then return silence end
  if f.n < 0 then return methods.rev(_fast(p, -f)) end
  local inv = ONE / f
  return withTime(p, function(t) return t * f end, function(t) return t * inv end)
end

local function _slow(p, f)
  f = tofrac(f)
  if f.n == 0 then return silence end
  return _fast(p, ONE / f)
end

local function _early(p, t)
  t = tofrac(t)
  return withTime(p, function(x) return x + t end, function(x) return x - t end)
end

local function _late(p, t) return _early(p, -tofrac(t)) end

local function fastcat(pats)
  if #pats == 0 then return silence end
  if #pats == 1 then return pats[1] end
  return _fast(slowcat(pats), #pats)
end

-- Squeezes each cycle of p into its first 1/factor, silence after.
local function _fastGap(p, factor)
  return splitQueries(pattern(function(s)
    local cycle = s.b:sam()
    local bpos = fmin((s.b - cycle) * factor, ONE)
    local epos = fmin((s.e - cycle) * factor, ONE)
    if bpos >= ONE then return {} end
    local out = {}
    for _, h in ipairs(p.query(span(cycle + bpos, cycle + epos))) do
      local pb, pe = h.part.b, h.part.e
      local hc = pb:sam()
      local nb = hc + fmin((pb - hc) / factor, ONE)
      local ne = hc + fmin((pe - hc) / factor, ONE)
      local whole
      if h.whole then whole = span(nb - (pb - h.whole.b) / factor, ne + (h.whole.e - pe) / factor) end
      out[#out + 1] = hap(whole, span(nb, ne), h.value)
    end
    return out
  end))
end

-- Each cycle of p squeezed into [b, e) of the cycle.
local function compress(p, b, e)
  b, e = tofrac(b), tofrac(e)
  if b >= e or b < ZERO or e > ONE then return silence end
  return _late(_fastGap(p, ONE / (e - b)), b)
end

-- Sequence of {weight, pattern}: each takes its share of the cycle.
local function timecat(items)
  local total = ZERO
  for _, it in ipairs(items) do total = total + tofrac(it[1]) end
  if total.n == 0 then return silence end
  local pats, pos = {}, ZERO
  local even = true
  for _, it in ipairs(items) do
    if tofrac(it[1]) ~= ONE then even = false end
  end
  if even then
    for i, it in ipairs(items) do pats[i] = it[2] end
    return fastcat(pats)
  end
  for _, it in ipairs(items) do
    local w = tofrac(it[1])
    if w.n > 0 then
      pats[#pats + 1] = compress(it[2], pos / total, (pos + w) / total)
      pos = pos + w
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

-- A random number in [0, 1) that depends only on the time t (a fraction)
-- and the seed: the same pattern plays the same "random" notes every time.
local function randAt(t, seed)
  local h = hash(t.n * 31337 + t.d * 7919 + (seed or 0) * 104729 + 1013)
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
    local c = s.b:sam()
    local i = math.floor(randAt(c, (seed or 0) + 7) * n) % n + 1
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
  for i, on in ipairs(bjorklund(k, n, r)) do pats[i] = pure(on) end
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
    local cycle = s.b:sam()
    local nxt = cycle + ONE
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
    local c = s.b:cyc() % n
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
    return _early(p, frac(s.b:cyc() % n, n)).query(s)
  end))
end

-- Repeats each event n times within its own length.
function methods.ply(p, n)
  n = math.tointeger(num(n))
  if not n or n < 1 then return p end
  local fn = frac(n)
  return pattern(function(s)
    local out = {}
    for _, h in ipairs(p.query(s)) do
      if h.whole then
        local step = (h.whole.e - h.whole.b) / fn
        for i = 0, n - 1 do
          local b = h.whole.b + step * i
          local w = span(b, b + step)
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
function methods.segment(p, n) return appLeft(_fast(pure(true), n), p, function(_, v) return v end) end

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
function methods.compress(p, b, e) return compress(p, b, e) end
function methods.fmap(p, f) return fmap(p, f) end
function methods.filter(p, f) return filterHaps(p, function(h) return f(h.value) end) end

-- Values within [lo, hi] instead of [0, 1].
function methods.range(p, lo, hi)
  return fmap(p, function(v) return num(v) * (hi - lo) + lo end)
end

function methods.query(p, b, e) return p.query(span(tofrac(b), tofrac(e))) end

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
-- timecat({3, "c e g"}, {1, "b"})
function M.timeCat(...)
  local items = {}
  for i, it in ipairs({...}) do items[i] = {it[1], reify(it[2])} end
  return timecat(items)
end
function M.rev(p) return methods.rev(reify(p)) end
M.slowcat, M.fastcat = slowcat, fastcat

local TAU = 2 * math.pi
M.sine = signal(function(t) return (math.sin(TAU * t:pos():num()) + 1) / 2 end)
M.cosine = _early(M.sine, frac(1, 4))
M.saw = signal(function(t) return t:pos():num() end)
M.isaw = signal(function(t) return 1 - t:pos():num() end)
M.tri = signal(function(t)
  local x = t:pos():num()
  return x < 0.5 and 2 * x or 2 - 2 * x
end)
M.square = signal(function(t) return t:pos():num() < 0.5 and 0 or 1 end)
M.rand = signal(function(t) return randAt(t, 99) end)
function M.irand(n) return fmap(M.rand, function(v) return math.floor(v * n) end) end
function M.run(n) -- 0 1 2 .. n-1
  local pats = {}
  for i = 0, n - 1 do pats[#pats + 1] = pure(i) end
  return fastcat(pats)
end

return M
