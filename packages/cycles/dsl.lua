-- cycles.dsl: runs the code typed in the editor and returns the pattern to
-- play. The code is Lua with the pattern functions in scope; a few Strudel
-- habits are accepted too, so most of its short examples run as they are:
--
--   note("c e g").s("saw")       methods with "." (or ":", the Lua way)
--   $: s("bd*4")                 several patterns, one per "$:" line
--   x => x.fast(2)               short functions ("function(x) return ... end")
--   // a comment                 on its own line (or "--")
--   `multi-line mini-notation`   backquotes (or [[ ]])
--   const a = ...                const and let are local
--
-- The value of the last expression is played; setcps(0.5) or setcpm(30)
-- sets the tempo (cycles per second, per minute).
local P = require "cycles.pattern"
local C = require "cycles.controls"
local mini = require "cycles.mini"

local M = {}
local methods = P.methods

-- --------------------------------------------------------------- translation

-- A Lua long string holding s: [[...]], or [=[...]=] and so on when s
-- contains "]]" (mini-notation often does: "[c5 b4]]").
local function longString(s)
  local eq = ""
  while s:find("]" .. eq .. "]", 1, true) do eq = eq .. "=" end
  -- A newline right after the opening bracket would be dropped by Lua.
  if s:sub(1, 1) == "\n" then s = "\n" .. s end
  return "[" .. eq .. "[" .. s .. "]" .. eq .. "]"
end

-- Calls f(text, inString) for the pieces of src outside and inside string
-- literals ("...", '...', [[...]] and `...`).
local function pieces(src, f)
  local out, i, n = {}, 1, #src
  while i <= n do
    local s = src:find("[\"'`%[]", i)
    if not s then
      out[#out + 1] = f(src:sub(i), false)
      break
    end
    local c = src:sub(s, s)
    local eq = c == "[" and src:match("^%[(=*)%[", s)
    if c == "[" and not eq then
      -- An index, not a long string.
      out[#out + 1] = f(src:sub(i, s), false)
      i = s + 1
    else
      local e
      if eq then
        e = select(2, src:find("]" .. eq .. "]", s, true))
      elseif c == "`" then
        e = src:find("`", s + 1, true)
      else
        -- Double quotes may span lines, as in Strudel; single quotes not.
        local j = s + 1
        while j <= n do
          local ch = src:sub(j, j)
          if ch == "\\" then
            j = j + 2
          elseif ch == c or (ch == "\n" and c == "'") then
            break
          else
            j = j + 1
          end
        end
        e = j
      end
      e = math.min(e or n, n)
      out[#out + 1] = f(src:sub(i, s - 1), false)
      local lit = src:sub(s, e)
      if c == "`" or (c == '"' and lit:find("\n", 1, true)) then lit = longString(lit:sub(2, -2)) end
      out[#out + 1] = f(lit, true)
      i = e + 1
    end
  end
  return table.concat(out)
end

-- "x => body" and "(x, y) => body" to Lua functions; the body ends at the
-- first "," or ")" outside brackets.
local function arrows(code)
  while true do
    local s, e, params = code:find("%(([%w_,%s]*)%)%s*=>%s*")
    if not s then
      s, e, params = code:find("([%a_][%w_]*)%s*=>%s*")
    end
    if not s then return code end
    local depth, j = 0, e + 1
    while j <= #code do
      local ch = code:sub(j, j)
      if ch == "(" or ch == "[" or ch == "{" then
        depth = depth + 1
      elseif ch == ")" or ch == "]" or ch == "}" then
        if depth == 0 then break end
        depth = depth - 1
      elseif ch == "," and depth == 0 then
        break
      elseif ch == "\n" and depth == 0 then
        break
      end
      j = j + 1
    end
    local body = code:sub(e + 1, j - 1)
    code = code:sub(1, s - 1) .. "function(" .. params .. ") return " .. body .. " end" .. code:sub(j)
  end
end

-- Strudel habits to Lua (outside strings). Returns the code with each
-- string literal replaced by "\1<n>\2", and a function that puts them back.
local function translate(src)
  src = src:gsub("\r", "")
  local lines = {}
  for line in (src .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("^(%s*)//", "%1--")
    line = line:gsub("^(%s*)%$:", "%1_[#_ + 1] =")
    line = line:gsub("^(%s*)const%s", "%1local ")
    line = line:gsub("^(%s*)let%s", "%1local ")
    lines[#lines + 1] = line
  end
  src = table.concat(lines, "\n")
  -- Strings are kept apart while arrows are rewritten.
  local saved = {}
  local code = pieces(src, function(text, inString)
    if inString then
      saved[#saved + 1] = text
      return "\1" .. #saved .. "\2"
    end
    return text
  end)
  code = arrows(code)
  return code, function(s)
    return (s:gsub("\1(%d+)\2", function(k) return saved[tonumber(k)] end))
  end
end

function M.translate(src)
  local code, restore = translate(src)
  return restore(code)
end

-- --------------------------------------------------------------- environment

-- Methods also exist as functions, the pattern last; given fewer arguments
-- they wait for it: every(4, fast(2)) or every(4, rev).
local ARITY = {
  fast = 1, slow = 1, early = 1, late = 1, rev = 0, every = 2, firstOf = 2, lastOf = 2,
  iter = 1, ply = 1, palindrome = 0, degradeBy = 1, degrade = 0, undegradeBy = 1,
  sometimesBy = 2, sometimes = 1, often = 1, rarely = 1, almostNever = 1, almostAlways = 1,
  off = 2, superimpose = 1, segment = 1, range = 2, add = 1, sub = 1, mul = 1, div = 1,
  struct = 1, euclid = 2, euclidRot = 3, scale = 1, compress = 2, density = 1, sparsity = 1,
}

local function curried(name, arity)
  local m = methods[name]
  return function(...)
    local n = select("#", ...)
    local args = {...}
    if n > arity then return m(P.reify(args[n]), table.unpack(args, 1, arity)) end
    return function(p) return m(P.reify(p), table.unpack(args, 1, n)) end
  end
end

local base = {
  math = math, string = string, table = table, utf8 = utf8,
  pairs = pairs, ipairs = ipairs, select = select, type = type, next = next,
  tostring = tostring, tonumber = tonumber, error = error, pcall = pcall,
  setmetatable = setmetatable, getmetatable = getmetatable, unpack = table.unpack,
  stack = P.stack, cat = P.cat, slowcat = P.cat, seq = P.seq, fastcat = P.seq, sequence = P.seq,
  timeCat = P.timeCat, timecat = P.timeCat, silence = P.silence, pure = P.pure,
  mini = mini.parse, m = mini.parse,
  sine = P.sine, cosine = P.cosine, saw = P.saw, isaw = P.isaw, tri = P.tri, square = P.square,
  rand = P.rand, irand = P.irand, run = P.run, signal = P.signal,
  adsr = C.adsr, midi = C.midi,
}
for name, arity in pairs(ARITY) do base[name] = curried(name, arity) end
for name, f in pairs(C) do
  if type(f) == "function" and base[name] == nil and name:match("^%l") and name ~= "render" and
     name ~= "rate" and name ~= "hz" then
    base[name] = f
  end
end
base.sound, base.s = C.s, C.s
M.base = base

-- --------------------------------------------------------------- evaluation

-- Runs code. Returns {pattern =, cps =, log =} or nil and the error.
function M.eval(src)
  local result = {log = {}}
  local collected = {}
  local env = setmetatable({}, {__index = base})
  env._ = collected
  env.setcps = function(x) result.cps = tonumber(x) end
  env.setcpm = function(x) result.cps = tonumber(x) / 60 end
  env.hush = function() return P.silence end
  env.print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
    result.log[#result.log + 1] = table.concat(t, " ")
  end
  env.play = function(p)
    collected[#collected + 1] = p
    return p
  end
  local saved = methods.play
  methods.play = function(p)
    collected[#collected + 1] = p
    return p
  end
  methods.p = methods.play

  local masked, restore = translate(src)
  local code = restore(masked)
  -- An expression first; else statements, the last one returned when it
  -- can be. Lines are looked at with the strings masked, so that a line
  -- inside a multi-line string is never taken for a statement.
  local chunk = load("return " .. code, "=code", "t", env)
  if not chunk then
    local lines = {}
    for line in (masked .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    for k = #lines, 1, -1 do
      local l = lines[k]
      if l:match("^[%a_\1%[%(]") and not l:match("^end") and not l:match("^local%s") and
         not l:match("^_%[") and not l:match("^%-%-") then
        local try = table.concat(lines, "\n", 1, k - 1) .. "\nreturn " .. table.concat(lines, "\n", k)
        chunk = load(restore(try), "=code", "t", env)
        break
      end
    end
  end
  local err
  if not chunk then chunk, err = load(code, "=code", "t", env) end
  if not chunk then
    methods.play = saved
    return nil, err
  end
  local ok, value = pcall(chunk)
  methods.play = saved
  methods.p = saved
  if not ok then return nil, tostring(value) end
  local pats = {}
  for _, p in ipairs(collected) do pats[#pats + 1] = P.reify(p) end
  if #pats == 0 and value ~= nil then
    ok, value = pcall(P.reify, value)
    if not ok then return nil, tostring(value) end
    pats[1] = value
  end
  result.pattern = #pats > 0 and P.stack(pats) or nil
  return result
end

return M
