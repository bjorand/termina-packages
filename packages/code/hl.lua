-- code.hl: syntax highlighting of Lua and shell lines, in Lua, for machines
-- without termina.hl (same results: the firmware's apps/highlight.cpp).
-- lua(line [, state [, attr]]) -> one attribute byte per byte of line, and
-- the state for the next line; sh(...) the same.
local M = {}

local KEYWORD, CONST, NUMBER, STRING, COMMENT, VAR = 0x0E, 0x0D, 0x0D, 0x0A, 0x08, 0x0B

local LUA_KEYWORDS = {}
for w in ("and break do else elseif end for function goto if in local not or repeat return then until while"):gmatch("%S+") do
  LUA_KEYWORDS[w] = true
end
local LUA_CONSTS = {["nil"] = true, ["true"] = true, ["false"] = true}

local SH_KEYWORDS = {}
for w in ("if then elif else fi for while until do done case esac function return break continue local export"):gmatch("%S+") do
  SH_KEYWORDS[w] = true
end
local SH_OPENS = {["if"] = true, ["then"] = true, ["elif"] = true, ["else"] = true, ["while"] = true, ["until"] = true, ["do"] = true}

local function isIdent(c)
  return c ~= "" and c:find("^[%w_]") ~= nil
end

-- Level of an opening long bracket "[==[" at i, or nil.
local function longOpen(s, i)
  local eq = s:match("^%[(=*)%[", i)
  return eq and #eq or nil
end

-- Position right after the "]==]" of the given level from i, or nil.
local function longClose(s, i, level)
  local _, z = s:find("]" .. string.rep("=", level) .. "]", i, true)
  return z and z + 1 or nil
end

-- string.char takes a limited number of arguments: long lines in pieces.
local function chars(attrs, n)
  local out = {}
  for i = 1, n, 4000 do out[#out + 1] = string.char(table.unpack(attrs, i, math.min(n, i + 3999))) end
  return table.concat(out)
end

function M.lua(s, state, base)
  state, base = state or 0, base or 0x07
  local n = #s
  local attrs = {}
  local bg = base & 0xF0
  for k = 1, n do attrs[k] = base end
  local function paint(a, b, fg)
    for k = a, math.min(b, n) do attrs[k] = bg | fg end
  end
  local function done(st) return chars(attrs, n), st end
  local i = 1
  if state ~= 0 then
    local level = (state >> 1) - 1
    local fg = (state & 1) ~= 0 and COMMENT or STRING
    local z = longClose(s, 1, level)
    if not z then
      paint(1, n, fg)
      return done(state)
    end
    paint(1, z - 1, fg)
    i = z
  end
  while i <= n do
    local c = s:sub(i, i)
    if c == "-" and s:sub(i + 1, i + 1) == "-" then
      local level = longOpen(s, i + 2)
      if not level then
        paint(i, n, COMMENT)
        return done(0)
      end
      local z = longClose(s, i + 4 + level, level)
      if not z then
        paint(i, n, COMMENT)
        return done(((level + 1) << 1) | 1)
      end
      paint(i, z - 1, COMMENT)
      i = z
    elseif c == "[" and longOpen(s, i) then
      local level = longOpen(s, i)
      local z = longClose(s, i + 2 + level, level)
      if not z then
        paint(i, n, STRING)
        return done((level + 1) << 1)
      end
      paint(i, z - 1, STRING)
      i = z
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n and s:sub(j, j) ~= c do j = j + (s:sub(j, j) == "\\" and 2 or 1) end
      j = j <= n and j or n
      paint(i, j, STRING)
      i = j + 1
    elseif c:find("%d") or (c == "." and s:sub(i + 1, i + 1):find("%d")) then
      local j = i + 1
      while j <= n do
        local d = s:sub(j, j)
        if isIdent(d) or d == "." or ((d == "+" or d == "-") and s:sub(j - 1, j - 1):find("[eEpP]")) then
          j = j + 1
        else
          break
        end
      end
      paint(i, j - 1, NUMBER)
      i = j
    elseif isIdent(c) then
      local j = i
      while j <= n and isIdent(s:sub(j, j)) do j = j + 1 end
      local w = s:sub(i, j - 1)
      if LUA_KEYWORDS[w] then paint(i, j - 1, KEYWORD)
      elseif LUA_CONSTS[w] then paint(i, j - 1, CONST) end
      i = j
    else
      i = i + 1
    end
  end
  return done(0)
end

-- Length of the variable reference ($name, ${...}, $1, $?, $( ) at i.
local function shVarLen(s, i)
  local n, j = #s, i + 1
  if j > n then return 1 end
  local c = s:sub(j, j)
  if c == "{" then
    local e = s:find("}", j, true)
    return e and e + 1 - i or n - i + 1
  end
  if c == "(" then return 2 end
  if c:find("[%d%?#%$!@%*%-]") then return 2 end
  while j <= n and isIdent(s:sub(j, j)) do j = j + 1 end
  return j - i
end

function M.sh(s, state, base)
  state, base = state or 0, base or 0x07
  local n = #s
  local attrs = {}
  local bg = base & 0xF0
  for k = 1, n do attrs[k] = base end
  local function paint(a, b, fg)
    for k = a, math.min(b, n) do attrs[k] = bg | fg end
  end
  local function done(st) return chars(attrs, n), st end
  -- a string opened by quote q, from i: the position after it, or nil
  local function str(from, q)
    local i = from
    while i <= n do
      local c = s:sub(i, i)
      if q == '"' and c == "\\" then
        attrs[i] = bg | STRING
        i = i + 1
        if i <= n then attrs[i] = bg | STRING end
      elseif q == '"' and c == "$" then
        local k = shVarLen(s, i)
        paint(i, i + k - 1, VAR)
        i = i + k - 1
      else
        attrs[i] = bg | STRING
        if c == q then return i + 1 end
      end
      i = i + 1
    end
    return nil
  end
  local i = 1
  if state ~= 0 then
    i = str(1, string.char(state))
    if not i then return done(state) end
  end
  local cmdPos = state == 0
  local wantIn = 0
  while i <= n do
    local c = s:sub(i, i)
    if c == "#" and (i == 1 or s:sub(i - 1, i - 1):find("[ \t;|&(]")) then
      paint(i, n, COMMENT)
      return done(0)
    elseif c == "'" or c == '"' then
      if wantIn > 0 then wantIn = wantIn - 1 end
      attrs[i] = bg | STRING
      i = str(i + 1, c)
      if not i then return done(c:byte()) end
      cmdPos = false
    elseif c == "\\" then
      i = i + 2
      cmdPos = false
    elseif c == "$" then
      if wantIn > 0 then wantIn = wantIn - 1 end
      local k = shVarLen(s, i)
      paint(i, i + k - 1, VAR)
      i = i + k
      cmdPos = false
    elseif isIdent(c) then
      local j = i
      while j <= n and isIdent(s:sub(j, j)) do j = j + 1 end
      local w = s:sub(i, j - 1)
      if wantIn > 0 then wantIn = wantIn - 1 end
      if cmdPos and s:sub(j, j) == "=" and not c:find("%d") then
        paint(i, j - 1, VAR)  -- NAME=value
        i = j + 1
      else
        if (cmdPos and SH_KEYWORDS[w]) or (wantIn == 1 and w == "in") then
          paint(i, j - 1, KEYWORD)
          cmdPos = SH_OPENS[w] == true
          if w == "for" or w == "case" then wantIn = 3 end
        else
          cmdPos = false
        end
        i = j
      end
    else
      if c:find("[;|&(){}!]") then cmdPos = true
      elseif c ~= " " and c ~= "\t" then cmdPos = false end
      i = i + 1
    end
  end
  return done(0)
end

return M
