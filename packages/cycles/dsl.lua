-- cycles.dsl: runs the code typed in the editor and returns the pattern to
-- play. The code is Lua with the pattern functions in scope; Strudel code
-- (JavaScript) is translated, so that most of it runs as it is:
--
--   note("c e g").s("saw")       methods with "." (or ":", the Lua way)
--   $: s("bd*4")                 several patterns, one per "$:" line
--   x => x.fast(2)               short functions
--   // and /* */ comments        (or "--")
--   `multi-line mini-notation`   backquotes (or [[ ]]), with methods:
--                                `<a b>`.add(12)
--   const a = ..., let b = ...   (globals at the start of a line, local
--                                when indented)
--   function f(x) { ... }        usable before it is defined, as in JS
--   if (c) { ... } else { ... }  and if (c) return x;
--   [2, pat]                     arrays; ===, !==, &&, ||, !, null
--
-- The value of the last expression is played; setcps(0.5) or setcpm(30)
-- sets the tempo (cycles per second, per minute).
local P = require "cycles.pattern"
local C = require "cycles.controls"
local mini = require "cycles.mini"

local M = {}
local methods = P.methods

-- --------------------------------------------------------------- translation

-- A Lua long bracket around s: "[[" .. s .. "]]", with as many "=" as
-- needed when s holds "]]" (mini-notation often does: "[c5 b4]]").
local function longBracket(s)
  local eq = ""
  while (s .. "]"):find("]" .. eq .. "]", 1, true) do eq = eq .. "=" end
  -- Lua drops a newline right after the opening bracket.
  if s:sub(1, 1) == "\n" then s = "\n" .. s end
  return "[" .. eq .. "[", s, "]" .. eq .. "]"
end

local function longString(s)
  local a, b, c = longBracket(s)
  return a .. b .. c
end

-- Splits src into code, string literals and comments. Literals and
-- comments are replaced by "\1<n>\2"; returns the masked code, the saved
-- pieces and which of them are comments.
local function mask(src)
  local out, saved, isComment = {}, {}, {}
  local function keep(text, comment)
    saved[#saved + 1] = text
    isComment[#saved] = comment
    out[#out + 1] = "\1" .. #saved .. "\2"
  end
  local i, n = 1, #src
  while i <= n do
    local s = src:find("[\"'`%[%-/]", i)
    if not s then
      out[#out + 1] = src:sub(i)
      break
    end
    out[#out + 1] = src:sub(i, s - 1)
    local c, two = src:sub(s, s), src:sub(s, s + 1)
    local eq = c == "[" and src:match("^%[(=*)%[", s)
    local ceq = two == "--" and src:match("^%-%-%[(=*)%[", s)
    if ceq then                                 -- --[[ long comment ]]
      local _, e = src:find("]" .. ceq .. "]", s, true)
      e = e or n
      keep(src:sub(s, e), true)
      i = e + 1
    elseif two == "--" then                     -- -- comment
      local e = (src:find("\n", s, true) or n + 1) - 1
      keep(src:sub(s, e), true)
      i = e + 1
    elseif two == "/*" then                     -- /* comment */
      local _, e = src:find("*/", s + 2, true)
      e = e or n
      local a, body, b = longBracket(src:sub(s + 2, e - 2))
      keep("--" .. a .. body .. b, true)
      i = e + 1
    elseif eq then                              -- [[ long string ]]
      local _, e = src:find("]" .. eq .. "]", s, true)
      e = e or n
      keep(src:sub(s, e), false)
      i = e + 1
    elseif c == "`" then                        -- `string`
      local e = src:find("`", s + 1, true) or n + 1
      keep(longString(src:sub(s + 1, e - 1)), false)
      i = e + 1
    elseif c == '"' or c == "'" then            -- "string"
      local j = s + 1
      while j <= n do
        local ch = src:sub(j, j)
        if ch == "\\" then
          j = j + 2
        elseif ch == c or ch == "\n" then
          break
        else
          j = j + 1
        end
      end
      j = math.min(j, n)
      keep(src:sub(s, j), false)
      i = j + 1
    else                                        -- [, - or / in code
      out[#out + 1] = c
      i = s + 1
    end
  end
  return table.concat(out), saved, isComment
end

-- The index of the bracket that closes the one at i ((, [ or {).
local function closing(code, i)
  local depth = 0
  for j = i, #code do
    local c = code:sub(j, j)
    if c == "(" or c == "[" or c == "{" then
      depth = depth + 1
    elseif c == ")" or c == "]" or c == "}" then
      depth = depth - 1
      if depth == 0 then return j end
    end
  end
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
      elseif (ch == "," or ch == "\n") and depth == 0 then
        break
      end
      j = j + 1
    end
    local body = code:sub(e + 1, j - 1)
    code = code:sub(1, s - 1) .. "function(" .. params .. ") return " .. body .. " end" .. code:sub(j)
  end
end

-- JavaScript blocks and arrays to Lua: function f(x) { } and if (c) { }
-- else { } get "end", [a, b] becomes {a, b}. Named functions at the top
-- level move to the start, since JS lets them be called before they are
-- defined.
local function blocks(code, isComment)
  local out, stack, hoisted = {}, {}, {}
  local i, n = 1, #code

  -- The last character of code written out, comments left aside.
  local function lastChar()
    for k = #out, 1, -1 do
      local t = out[k]:gsub("\1(%d+)\2", function(x) if isComment[tonumber(x)] then return "" end end)
      local ch = t:match("(%S)%s*$")
      if ch then return ch end
    end
    return ""
  end

  -- At i, after "if" and its condition (p..q): "{" opens a block, else one
  -- statement up to ";" or the end of the line. Returns the new i, or nil
  -- when it is Lua ("if (a) then").
  local function ifAt(cond, q, prefix)
    local r = code:find("%S", q + 1)
    if r and code:sub(r, r) == "{" then
      out[#out + 1] = prefix .. " " .. cond .. " then"
      return r + 1, true
    end
    local e = code:find("[;\n]", q + 1) or n + 1
    local stmt = code:sub(q + 1, e - 1)
    if stmt:find("%f[%w_]then%f[^%w_]") then return nil end
    if stmt:match("^%s*$") or stmt:match("^%s*[=~<>%+%*/%%%^%.]") or stmt:match("^%s*and%f[^%w_]") or
       stmt:match("^%s*or%f[^%w_]") then
      return nil
    end
    out[#out + 1] = prefix .. " " .. cond .. " then" .. stmt .. " end"
    return e, false
  end

  while i <= n do
    local c = code:sub(i, i)
    if c:match("[%a_]") then
      local w = code:match("^[%a_][%w_]*", i)
      local j = i + #w
      local done = false
      if w == "function" then
        local p = code:find("%S", j)
        local name = p and code:match("^[%a_][%w_%.]*", p) or ""
        if name ~= "" then p = code:find("%S", p + #name) end
        if p and code:sub(p, p) == "(" then
          local q = closing(code, p)
          local r = q and code:find("%S", q + 1)
          if r and code:sub(r, r) == "{" then
            local hoist = #stack == 0 and name ~= "" and #out + 1
            stack[#stack + 1] = {close = "end", hoist = hoist}
            out[#out + 1] = "function " .. name .. code:sub(p, q)
            i, done = r + 1, true
          end
        end
      elseif w == "if" then
        local p = code:find("%S", j)
        if p and code:sub(p, p) == "(" then
          local q = closing(code, p)
          if q then
            local ni, block = ifAt(code:sub(p + 1, q - 1), q, "if")
            if ni then
              if block then stack[#stack + 1] = {close = "end"} end
              i, done = ni, true
            end
          end
        end
      end
      if not done then
        out[#out + 1] = w
        i = j
      end
    elseif c == "{" or c == "(" then
      stack[#stack + 1] = {close = c == "{" and "}" or ")"}
      out[#out + 1] = c
      i = i + 1
    elseif c == "[" then
      -- An index after a name or a closing bracket, a table key before
      -- "=", else an array.
      local q = closing(code, i)
      local key = q and code:match("^%s*=[^=]", q + 1)
      if lastChar():match("[%w_%)%]}\2]") or key then
        stack[#stack + 1] = {close = "]"}
        out[#out + 1] = "["
      else
        stack[#stack + 1] = {close = "}"}
        out[#out + 1] = "{"
      end
      i = i + 1
    elseif c == "}" or c == "]" or c == ")" then
      local top = table.remove(stack)
      i = i + 1
      if not top then
        out[#out + 1] = c
      elseif top.close == "end" then
        local after = code:match("^%s*else%s*()", i)
        local elseIf = after and code:match("^if%s*()%(", after)
        local q = elseIf and closing(code, elseIf)
        local ni, block
        if q then ni, block = ifAt(code:sub(elseIf + 1, q - 1), q, " elseif") end
        if ni then
          -- "} else if (c) {" goes on; "} else if (c) x;" ends with x.
          if block then stack[#stack + 1] = top end
          i = ni
        elseif after and code:sub(after, after) == "{" then
          out[#out + 1] = " else"
          stack[#stack + 1] = top
          i = after + 1
        else
          out[#out + 1] = "end"
          if top.hoist then
            local seg = table.concat(out, "", top.hoist)
            for k = #out, top.hoist, -1 do out[k] = nil end
            hoisted[#hoisted + 1] = seg
          end
        end
      else
        out[#out + 1] = top.close
      end
    else
      local e = code:find("[%a_{}%[%]%(%)]", i) or n + 1
      out[#out + 1] = code:sub(i, e - 1)
      i = e
    end
  end
  if #hoisted == 0 then return table.concat(out) end
  -- On one line, so that the line numbers of errors stay right below; the
  -- comments go (one would hide the rest of the line).
  local top = {}
  for k, h in ipairs(hoisted) do
    h = h:gsub("\1(%d+)\2", function(x) if isComment[tonumber(x)] then return " " end end)
    top[k] = (h:gsub("\n", " "))
  end
  return table.concat(top, " ") .. " " .. table.concat(out)
end

-- JS operators and values to Lua.
local function operators(code)
  code = code:gsub("===", "=="):gsub("!==", "~="):gsub("!=", "~=")
  code = code:gsub("&&", " and "):gsub("||", " or "):gsub("!", " not ")
  code = code:gsub("%f[%w_]null%f[^%w_]", "nil"):gsub("%f[%w_]undefined%f[^%w_]", "nil")
  return code
end

-- Strudel habits to Lua. Returns the code with the strings and comments
-- masked ("\1<n>\2"), and a function that puts them back.
local function translate(src)
  src = src:gsub("\r", "")
  local lines = {}
  for line in (src .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("^(%s*)//", "%1--")
    line = line:gsub("^(%s*)%$:", "%1_[#_ + 1] =")
    -- const and let: globals at the top level (functions defined in JS
    -- style see them), locals when indented.
    line = line:gsub("^(%s*)const%s+", function(sp) return sp == "" and "" or sp .. "local " end)
    line = line:gsub("^(%s*)let%s+", function(sp) return sp == "" and "" or sp .. "local " end)
    lines[#lines + 1] = line
  end
  local code, saved, isComment = mask(table.concat(lines, "\n"))
  code = arrows(code)
  code = blocks(code, isComment)
  code = operators(code)
  -- A trailing comma before ")" (JS allows it, Lua does not), comments
  -- between them included.
  code = code:gsub(",([%s\1\2%d]*%))", function(rest)
    for k in rest:gmatch("\1(%d+)\2") do
      if not isComment[tonumber(k)] then return nil end
    end
    return rest
  end)
  -- Methods on string literals: `<a b>`.add(12) -> ([[<a b>]]).add(12).
  code = code:gsub("\1(%d+)\2(%s*[%.:][%a_])", function(k, rest)
    if isComment[tonumber(k)] then return nil end
    return "(\1" .. k .. "\2)" .. rest
  end)
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
  adsr = C.adsr, midi = C.midi, arrange = P.arrange,
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
      if l:match("^[%a_\1%(]") and not l:match("^end") and not l:match("^local%s") and
         not l:match("^_%[") and not l:match("^\1.-\2%s*$") and not l:match("^[%a_][%w_]*%s*=[^=]") then
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
    methods.p = saved
    return nil, err
  end
  -- While the code runs, strings have the pattern methods too:
  -- ("<a b>"):add(12), as JS strings in Strudel.
  local smt = getmetatable("")
  local sindex = smt.__index
  smt.__index = function(s, k)
    local f = string[k]
    if f ~= nil then return f end
    if methods[k] then return P.reify(s)[k] end
  end
  C.ignoredUsed = {}
  local ok, value = pcall(chunk)
  smt.__index = sindex
  methods.play = saved
  methods.p = saved
  if not ok then return nil, tostring(value) end
  local ignored = {}
  for name in pairs(C.ignoredUsed) do ignored[#ignored + 1] = name end
  if #ignored > 0 then
    table.sort(ignored)
    result.log[#result.log + 1] = "Not on the sound card, ignored: " .. table.concat(ignored, ", ")
  end
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
