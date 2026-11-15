-- cycles.mini: the mini-notation of TidalCycles and Strudel, a string that
-- describes a pattern, compiled to cycles.pattern.
--
--   "a b c"       a sequence: three steps in one cycle
--   "~" or "-"    a rest
--   "[a b] c"     a subsequence in one step
--   "<a b c>"     one step per cycle, in turn
--   "a, b"        at the same time (in brackets too: "[c3, e3, g3]")
--   "a | b"       one of them per cycle, at random
--   "a . b c"     groups, like "[a] [b c]"
--   a*2 a/2       faster, slower (the factor can be "<2 3>" too)
--   a!3, a !      repeated: "a a a"
--   a@3, a _ _    longer than the other steps
--   a? a?0.3      left out at random (half of the time, 30%)
--   a(3,8,2)      euclidean rhythm: 3 onsets over 8 steps, rotated by 2
--
-- Words are kept as strings ("c#4", "bd:3") and numbers become numbers.
--
-- The string is cut into tokens by two C calls (gsub, gmatch), then read
-- token by token: on the ESP32 every Lua call costs, and a song holds
-- dozens of these strings. Parsed strings are kept: a string met again
-- (in the same code or the next time it runs) costs nothing.
local P = require "cycles.pattern"

local M = {}

-- Parsed strings: weakly by string, and for sure those of the code run
-- last and the time before (M.newRun), so that running it again after an
-- edit parses only the strings that changed.
local cache = setmetatable({}, {__mode = "v"})
local keepNow, keepBefore = {}, {}

function M.newRun()
  keepBefore, keepNow = keepNow, {}
end

-- Called before each string actually parsed (not found in the cache): a
-- player can queue its music meanwhile (M.busy = function() ... end).
M.busy = nil

local function fail(S, msg)
  error(string.format("mini: %s near %q in %q", msg, S.toks[S.k] or "the end", S.src), 0)
end

local function value(w)
  local n = tonumber(w)
  if n then return n end
  return w
end

-- Stop tokens of each kind of sequence.
local STOP_TOP = {[","] = true, ["|"] = true}
local STOP_BRACKET = {[","] = true, ["|"] = true, ["]"] = true}
local STOP_ANGLE = {[","] = true, ["|"] = true, [">"] = true}
local STOP_EUCLID = {[","] = true, [")"] = true}

local parseStack, parseSequence, parseStep

-- Items {weight, pattern} of a list of steps.
local function items(steps)
  local out = {}
  for i, st in ipairs(steps) do out[i] = {st.weight, st.pat} end
  return out
end

-- The arguments of an euclidean rhythm, at "(": (k, n[, r]).
local function euclid(S, st)
  S.k = S.k + 1
  local args, plain = {}, true
  while true do
    local steps = parseSequence(S, STOP_EUCLID)
    local arg
    if #steps == 1 and steps[1].num ~= nil then
      arg = steps[1].num
    else
      plain = false
      arg = P.timecat(items(steps))
    end
    args[#args + 1] = arg
    local t = S.toks[S.k]
    S.k = S.k + 1
    if t == ")" then break end
    if t ~= "," then fail(S, "')' expected") end
  end
  if #args < 2 or #args > 3 then fail(S, "euclid takes 2 or 3 numbers") end
  local p = st.pat
  if plain then return P.methods.euclid(p, args[1], args[2], args[3]) end
  -- Patterned arguments: "c(<3 5>,8)".
  local function pat(x) return P.isPattern(x) and x or P.pure(x) end
  local both = P.appLeft(P.appLeft(pat(args[1]), pat(args[2]), function(a, b) return {a, b} end),
                         pat(args[3] or 0), function(a, b) return {a[1], a[2], b} end)
  return P.innerJoin(P.fmap(both, function(t) return P.methods.euclid(p, t[1], t[2], t[3]) end))
end

-- Modifiers in a token: "*2", "@3", "?", "!2", "/2?0.3"...
local function modify(S, st, mods)
  for op, arg in mods:gmatch("([%*/!@%?])([^%*/!@%?]*)") do
    if op == "*" or op == "/" then
      local f
      if arg == "" then
        f = parseStep(S, true)  -- a pattern: "a*<2 3>"
      else
        f = tonumber(arg) or fail(S, "bad factor")
      end
      st.pat = op == "*" and P.methods.fast(st.pat, f) or P.methods.slow(st.pat, f)
      st.num = nil
    elseif op == "!" then
      st.count = st.count + (arg == "" and 1 or (tonumber(arg) or fail(S, "bad count")) - 1)
    elseif op == "@" then
      st.weight = tonumber(arg) or fail(S, "a weight expected after @")
    else
      S.seed = S.seed + 1
      st.pat = P.degradeBy(st.pat, arg == "" and 0.5 or (tonumber(arg) or fail(S, "bad amount")), S.seed)
      st.num = nil
    end
  end
end

-- One step: a word or a group, and its modifiers. Returns {pat, weight,
-- count, num (a plain number)}, or the pattern alone when bare.
function parseStep(S, bare)
  local t = S.toks[S.k]
  local st = {weight = 1, count = 1}
  local mods
  if t == "[" then
    S.k = S.k + 1
    st.pat = parseStack(S, "]")
  elseif t == "<" then
    S.k = S.k + 1
    st.pat = parseStack(S, ">", true)
  elseif t == "{" then
    fail(S, "polymeters { } are not supported")
  else
    local base
    base, mods = t:match("^([^%*/!@%?]+)(.*)$")
    if not base then fail(S, "a step is needed first") end
    S.k = S.k + 1
    if base == "~" or base == "-" then
      st.pat = P.silence
    else
      local v = value(base)
      st.pat = P.pure(v)
      if type(v) == "number" then st.num = v end
    end
  end
  if bare then return st.pat end
  if mods and mods ~= "" then modify(S, st, mods) end
  -- Modifiers after a group ("[a b]*2"), elongation, euclid.
  while true do
    t = S.toks[S.k]
    if t == "(" then
      st.pat = euclid(S, st)
      st.num = nil
    elseif t == "_" then
      st.weight = st.weight + 1
      S.k = S.k + 1
    elseif t and t:find("^[%*/!@%?]") then
      S.k = S.k + 1
      modify(S, st, t)
    else
      break
    end
  end
  return st
end

-- Steps up to a stop token (not taken). Repeats become separate steps.
function parseSequence(S, stop)
  local steps, feet = {}, nil
  while true do
    local t = S.toks[S.k]
    if t == nil or stop[t] then break end
    if t == "." then
      feet = feet or {}
      feet[#feet + 1] = steps
      steps = {}
      S.k = S.k + 1
    elseif t == ")" or t == "]" or t == ">" then
      fail(S, "unexpected '" .. t .. "'")
    else
      local st = parseStep(S)
      for _ = 1, st.count do steps[#steps + 1] = st end
    end
  end
  if feet then
    feet[#feet + 1] = steps
    local out = {}
    for i, f in ipairs(feet) do out[i] = {pat = P.timecat(items(f)), weight = 1, count = 1} end
    return out
  end
  return steps
end

-- Sequences separated by "," (together) or "|" (one of them), up to close.
-- alternate: "<...>", each sequence plays one step per cycle.
function parseStack(S, close, alternate)
  local stop = close == "]" and STOP_BRACKET or close == ">" and STOP_ANGLE or STOP_TOP
  local pats, sep = {}, nil
  while true do
    local steps = parseSequence(S, stop)
    local p = P.timecat(items(steps))
    if alternate then
      local total = 0
      for _, st in ipairs(steps) do total = total + st.weight end
      if total > 0 then p = P.methods.slow(p, total) end
    end
    pats[#pats + 1] = p
    local t = S.toks[S.k]
    if t == "," or t == "|" then
      if sep and sep ~= t then fail(S, "',' and '|' cannot be mixed") end
      sep = t
      S.k = S.k + 1
    elseif close and t == close then
      S.k = S.k + 1
      break
    elseif t == nil then
      if close then fail(S, "'" .. close .. "' expected") end
      break
    else
      fail(S, "unexpected '" .. t .. "'")
    end
  end
  if sep == "|" then
    S.seed = S.seed + 1
    return P.randcat(pats, S.seed)
  end
  return P.stack(pats)
end

-- Parses src; returns a pattern, or raises "mini: <why> near <token>".
function M.parse(src)
  local p = cache[src]
  if p then
    keepNow[src] = p
    return p
  end
  if M.busy then M.busy() end
  local toks = {}
  for t in src:gsub("[%[%]<>,|%(%){}]", " %0 "):gmatch("%S+") do toks[#toks + 1] = t end
  local S = {toks = toks, k = 1, seed = 0, src = src}
  p = parseStack(S, nil)
  cache[src], keepNow[src] = p, p
  return p
end

P.parse = M.parse

return M
