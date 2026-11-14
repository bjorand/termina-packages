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
local P = require "cycles.pattern"

local M = {}

local WORD = "^[%w#%.%-:_']+"

-- Parses src; returns a pattern, or raises "mini: <why> at <column>".
function M.parse(src)
  local i = 1
  local seed = 0

  local function fail(msg) error(string.format("mini: %s at column %d of %q", msg, i, src), 0) end

  local function ws()
    i = src:find("[^%s]", i) or #src + 1
  end

  local function peek()
    ws()
    return src:sub(i, i)
  end

  local function value(w)
    local n = tonumber(w)
    if n then return n end
    return w
  end

  local parseStack, parseSequence, parseStep

  -- A factor after * or /: a number, or a bracketed pattern.
  local function parseFactor()
    local c = src:sub(i, i)
    if c == "[" or c == "<" then return parseStep(true) end
    local s, e = src:find("^%-?[%d%.]+", i)
    if not s then fail("a number expected") end
    i = e + 1
    return tonumber(src:sub(s, e)) or fail("bad number")
  end

  -- The arguments of an euclidean rhythm: (k, n[, r]).
  local function parseEuclid(p)
    i = i + 1
    local args, plain = {}, true
    while true do
      local steps = parseSequence({[","] = true, [")"] = true})
      local arg
      if #steps == 1 and steps[1].num ~= nil then
        arg = steps[1].num
      else
        plain = false
        arg = P.timecat((function()
          local items = {}
          for k, st in ipairs(steps) do items[k] = {st.weight, st.pat} end
          return items
        end)())
      end
      args[#args + 1] = arg
      local c = peek()
      if c == ")" then
        i = i + 1
        break
      elseif c == "," then
        i = i + 1
      else
        fail("')' expected")
      end
    end
    if #args < 2 or #args > 3 then fail("euclid takes 2 or 3 numbers") end
    if plain then return P.methods.euclid(p, args[1], args[2], args[3]) end
    -- Patterned arguments: "c(<3 5>,8)".
    local function pat(x) return P.isPattern(x) and x or P.pure(x) end
    local k, n, r = pat(args[1]), pat(args[2]), pat(args[3] or 0)
    local both = P.appLeft(P.appLeft(k, n, function(a, b) return {a, b} end), r,
                           function(a, b) return {a[1], a[2], b} end)
    return P.innerJoin(P.fmap(both, function(t) return P.methods.euclid(p, t[1], t[2], t[3]) end))
  end

  -- One step: an atom or a group, then its modifiers. Returns {pat, weight,
  -- count (repeats), num (when a plain number)}.
  function parseStep(bare)
    local c = peek()
    local st = {weight = 1, count = 1}
    if c == "[" then
      i = i + 1
      st.pat = parseStack("]")
    elseif c == "<" then
      i = i + 1
      st.pat = parseStack(">", true)
    elseif c == "~" then
      i = i + 1
      st.pat = P.silence
    elseif c == "{" then
      fail("polymeters { } are not supported")
    else
      local s, e = src:find(WORD, i)
      if not s then fail("unexpected '" .. c .. "'") end
      local w = src:sub(s, e)
      i = e + 1
      if w == "-" then
        st.pat = P.silence
      else
        local v = value(w)
        st.pat = P.pure(v)
        if type(v) == "number" then st.num = v end
      end
    end
    if bare then return st.pat end
    -- Modifiers, glued to the step.
    while true do
      c = src:sub(i, i)
      if c == "*" or c == "/" then
        i = i + 1
        local f = parseFactor()
        st.pat = c == "*" and P.methods.fast(st.pat, f) or P.methods.slow(st.pat, f)
        st.num = nil
      elseif c == "!" then
        local s, e = src:find("^!%d+", i)
        if s then
          st.count = st.count + tonumber(src:sub(s + 1, e)) - 1
          i = e + 1
        else
          st.count = st.count + 1
          i = i + 1
        end
      elseif c == "@" then
        local s, e = src:find("^@[%d%.]+", i)
        if not s then fail("a weight expected after @") end
        st.weight = tonumber(src:sub(s + 1, e)) or fail("bad weight")
        i = e + 1
      elseif c == "?" then
        local s, e = src:find("^%?[%d%.]+", i)
        local amount = 0.5
        if s then
          amount = tonumber(src:sub(s + 1, e)) or fail("bad amount")
          i = e + 1
        else
          i = i + 1
        end
        seed = seed + 1
        st.pat = P.degradeBy(st.pat, amount, seed)
        st.num = nil
      elseif c == "(" then
        st.pat = parseEuclid(st.pat)
        st.num = nil
      elseif c == ":" then
        fail("':' must follow a word")
      else
        break
      end
    end
    return st
  end

  -- Steps until one of the stop characters (not consumed).
  function parseSequence(stop)
    local steps, feet = {}, nil
    while true do
      local c = peek()
      if c == "" or stop[c] then break end
      local s, e = src:find("^[%._!]%f[%s%]%>,|%)%z]", i)
      if s then
        local w = src:sub(s, e)
        i = e + 1
        local last = steps[#steps]
        if w == "." then
          feet = feet or {}
          feet[#feet + 1] = steps
          steps = {}
        elseif not last then
          fail("'" .. w .. "' needs a step before it")
        elseif w == "_" then
          last.weight = last.weight + 1
        else
          last.count = last.count + 1
        end
      else
        steps[#steps + 1] = parseStep()
      end
    end
    -- Repeats become separate steps.
    local function expand(list)
      local out = {}
      for _, st in ipairs(list) do
        for _ = 1, st.count do out[#out + 1] = {pat = st.pat, weight = st.weight, num = st.num} end
      end
      return out
    end
    if feet then
      feet[#feet + 1] = steps
      local out = {}
      for k, f in ipairs(feet) do
        local items = {}
        for j, st in ipairs(expand(f)) do items[j] = {st.weight, st.pat} end
        out[k] = {pat = P.timecat(items), weight = 1}
      end
      return out
    end
    return expand(steps)
  end

  -- Sequences separated by "," (together) or "|" (one of them), up to close.
  -- alternate: "<...>", each sequence plays one step per cycle.
  function parseStack(close, alternate)
    local stop = {[","] = true, ["|"] = true}
    if close then stop[close] = true end
    local pats, sep = {}, nil
    while true do
      local steps = parseSequence(stop)
      local items, total = {}, 0
      for k, st in ipairs(steps) do
        items[k] = {st.weight, st.pat}
        total = total + st.weight
      end
      local p = P.timecat(items)
      if alternate and total > 0 then p = P.methods.slow(p, total) end
      pats[#pats + 1] = p
      local c = peek()
      if c == "," or c == "|" then
        if sep and sep ~= c then fail("',' and '|' cannot be mixed") end
        sep = c
        i = i + 1
      elseif close and c == close then
        i = i + 1
        break
      elseif c == "" then
        if close then fail("'" .. close .. "' expected") end
        break
      else
        fail("unexpected '" .. c .. "'")
      end
    end
    if sep == "|" then
      seed = seed + 1
      return P.randcat(pats, seed)
    end
    return P.stack(pats)
  end

  return parseStack(nil)
end

P.parse = M.parse

return M
