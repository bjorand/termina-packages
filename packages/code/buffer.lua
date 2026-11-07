-- code.buffer: the text of a file being edited. Lines are UTF-8 strings;
-- positions are (line, column), lines from 1, columns from 0, counted in
-- characters. Edits go through insert() and delete(), which keep the undo
-- history and invalidate the highlighting from the line they touch.
local fs, hl = termina.fs, termina.hl
local ui = require "code.ui"

local len, offset = ui.len, ui.offset

local M = {}
local B = {}
B.__index = B

local TAB = 4
local MAX_UNDO = 2000
local MAX_SIZE = 512 * 1024

local function split(text)
  local out = {}
  local i = 1
  while true do
    local j = text:find("\n", i, true)
    if not j then
      out[#out + 1] = text:sub(i)
      return out
    end
    out[#out + 1] = text:sub(i, j - 1)
    i = j + 1
  end
end
M.split = split

local function expandTabs(s)
  if not s:find("\t", 1, true) then return s end
  local out, col = {}, 0
  for ch in s:gmatch(utf8.charpattern) do
    if ch == "\t" then
      local n = TAB - col % TAB
      out[#out + 1] = string.rep(" ", n)
      col = col + n
    else
      out[#out + 1] = ch
      col = col + 1
    end
  end
  return table.concat(out)
end

local function langOf(path)
  if not path then return nil end
  if path:match("%.lua$") then return "lua" end
  if path:match("%.sh$") then return "sh" end
  return nil
end
M.langOf = langOf

-- A new buffer; with a path, the file is read (missing: a new file).
-- Returns nil, message if it cannot be read.
function M.new(path)
  local b = setmetatable({
    path = path, lines = {""}, cy = 1, cx = 0, want = 0, top = 1, left = 0,
    undos = {}, redos = {}, group = 0, lastKind = nil, saved = 0, changes = 0,
    hlState = {[1] = 0}, hlAttr = {}, hlDone = 0, lang = langOf(path),
    marks = {}, diags = {},
  }, B)
  if path and fs.exists(path) then
    local size = fs.size(path)
    if size and size > MAX_SIZE then return nil, "file too big (512 KB at most)" end
    local text = fs.read(path)
    if not text then return nil, "cannot read " .. path end
    if text:find("\0", 1, true) then return nil, "binary file" end
    b.crlf = text:find("\r\n", 1, true) ~= nil
    if b.crlf then text = text:gsub("\r\n", "\n") end
    b.tabs = text:find("\t", 1, true) ~= nil
    b.lines = split(text)
    if b.tabs then
      for i, l in ipairs(b.lines) do b.lines[i] = expandTabs(l) end
    end
  end
  return b
end

-- A read-only buffer holding text (a diff, a listing).
function M.scratch(name, text, lang)
  local b = M.new(nil)
  b.name, b.readonly, b.lang = name, true, lang
  b.lines = split(text)
  return b
end

function B:title()
  return self.name or (self.path and self.path:match("[^/]*$")) or "untitled"
end

function B:modified()
  return self.changes ~= self.saved
end

function B:text()
  return table.concat(self.lines, "\n")
end

function B:save(path)
  path = path or self.path
  if not path then return nil, "no file name" end
  local text = self:text()
  if self.crlf then text = text:gsub("\n", "\r\n") end
  if not fs.write(path, text) then return nil, "cannot write " .. path end
  if path ~= self.path then
    self.path, self.name = path, nil
    self.lang = langOf(path)
    self:invalidate(1)
  end
  self.saved = self.changes
  return true
end

function B:lineLen(l)
  return len(self.lines[l] or "")
end

-- ------------------------------------------------------------------ editing

function B:invalidate(l)
  if l - 1 < self.hlDone then self.hlDone = math.max(0, l - 1) end
end

-- Text from (l1, c1) to (l2, c2), "\n" between lines.
function B:get(l1, c1, l2, c2)
  local lines = self.lines
  if l1 == l2 then
    local s = lines[l1]
    return s:sub(offset(s, c1), offset(s, c2) - 1)
  end
  local out = {lines[l1]:sub(offset(lines[l1], c1))}
  for l = l1 + 1, l2 - 1 do out[#out + 1] = lines[l] end
  out[#out + 1] = lines[l2]:sub(1, offset(lines[l2], c2) - 1)
  return table.concat(out, "\n")
end

local function rawInsert(self, l, c, text)
  local lines = self.lines
  local s = lines[l]
  local b = offset(s, c)
  local head, tail = s:sub(1, b - 1), s:sub(b)
  local parts = split(text)
  local n = #parts
  if n == 1 then
    lines[l] = head .. text .. tail
    return l, c + len(text)
  end
  table.move(lines, l + 1, #lines, l + n)  -- room for n - 1 new lines
  lines[l] = head .. parts[1]
  for i = 2, n - 1 do lines[l + i - 1] = parts[i] end
  lines[l + n - 1] = parts[n] .. tail
  return l + n - 1, len(parts[n])
end

local function rawDelete(self, l1, c1, l2, c2)
  local lines = self.lines
  local text = self:get(l1, c1, l2, c2)
  local a, z = lines[l1], lines[l2]
  lines[l1] = a:sub(1, offset(a, c1) - 1) .. z:sub(offset(z, c2))
  if l2 > l1 then
    local count = #lines
    table.move(lines, l2 + 1, count, l1 + 1)
    for i = count - (l2 - l1) + 1, count do lines[i] = nil end
  end
  return text
end

-- Starts an undo group unless this edit continues the previous one (typing
-- or erasing on: kind "type", "erase"...).
function B:begin(kind)
  if not kind or kind ~= self.lastKind then self.group = self.group + 1 end
  self.lastKind = kind
end

local function record(self, op)
  op.group = self.group
  op.cy, op.cx = self.cy, self.cx
  local u = self.undos
  u[#u + 1] = op
  if #u > MAX_UNDO then table.remove(u, 1) end
  self.redos = {}
  self.changes = self.changes + 1
end

-- Inserts text at (l, c); returns the position after it.
function B:insert(l, c, text)
  if text == "" then return l, c end
  record(self, {insert = true, l = l, c = c, text = text})
  self:invalidate(l)
  return rawInsert(self, l, c, text)
end

-- Deletes from (l1, c1) to (l2, c2); returns the text removed.
function B:delete(l1, c1, l2, c2)
  if l1 == l2 and c1 == c2 then return "" end
  local text = rawDelete(self, l1, c1, l2, c2)
  record(self, {insert = false, l = l1, c = c1, text = text})
  self:invalidate(l1)
  return text
end

local function endOf(l, c, text)
  local parts = split(text)
  if #parts == 1 then return l, c + len(text) end
  return l + #parts - 1, len(parts[#parts])
end

local function replay(self, op, undo)
  local inserting = op.insert ~= undo
  if inserting then
    rawInsert(self, op.l, op.c, op.text)
  else
    local l2, c2 = endOf(op.l, op.c, op.text)
    rawDelete(self, op.l, op.c, l2, c2)
  end
  self:invalidate(op.l)
end

function B:undo()
  local u = self.undos
  if #u == 0 then return false end
  local g = u[#u].group
  while #u > 0 and u[#u].group == g do
    local op = table.remove(u)
    replay(self, op, true)
    self.redos[#self.redos + 1] = op
    self.cy, self.cx = op.cy, op.cx
    self.changes = self.changes - 1
  end
  self.ay, self.lastKind = nil, nil
  return true
end

function B:redo()
  local r = self.redos
  if #r == 0 then return false end
  local g = r[#r].group
  while #r > 0 and r[#r].group == g do
    local op = table.remove(r)
    replay(self, op, false)
    self.undos[#self.undos + 1] = op
    if op.insert then self.cy, self.cx = endOf(op.l, op.c, op.text)
    else self.cy, self.cx = op.l, op.c end
    self.changes = self.changes + 1
  end
  self.ay, self.lastKind = nil, nil
  return true
end

-- ------------------------------------------------------------------ cursor

-- The selection in text order: l1, c1, l2, c2; nil if none.
function B:selection()
  if not self.ay then return nil end
  local l1, c1, l2, c2 = self.ay, self.ax, self.cy, self.cx
  if l1 > l2 or (l1 == l2 and c1 > c2) then l1, c1, l2, c2 = l2, c2, l1, c1 end
  if l1 == l2 and c1 == c2 then return nil end
  return l1, c1, l2, c2
end

function B:selectedText()
  local l1, c1, l2, c2 = self:selection()
  return l1 and self:get(l1, c1, l2, c2) or nil
end

-- Moves the cursor; with select, the selection follows (it starts at the
-- old position).
function B:moveTo(l, c, select)
  if select then
    if not self.ay then self.ay, self.ax = self.cy, self.cx end
  else
    self.ay = nil
  end
  l = math.max(1, math.min(l, #self.lines))
  c = math.max(0, math.min(c, self:lineLen(l)))
  self.cy, self.cx = l, c
  self.lastKind = nil
end

function B:selectAll()
  self.ay, self.ax = 1, 0
  self.cy, self.cx = #self.lines, self:lineLen(#self.lines)
end

function B:deleteSelection()
  local l1, c1, l2, c2 = self:selection()
  if not l1 then return false end
  self:delete(l1, c1, l2, c2)
  self.cy, self.cx, self.ay = l1, c1, nil
  return true
end

-- Types text at the cursor, replacing the selection.
function B:type(text, kind)
  if self.readonly then return end
  self:begin(kind or "type")
  if self:deleteSelection() then self:begin(nil) end
  self.cy, self.cx = self:insert(self.cy, self.cx, text)
  self.want = self.cx
end

-- Leading spaces of line l.
function B:indent(l)
  return (self.lines[l] or ""):match("^ *")
end

-- ------------------------------------------------------------------ words

local function isWord(ch)
  return ch:find("^[%w_]") ~= nil or #ch > 1
end

-- Start and end columns of the word at (l, c), or nil.
function B:wordAt(l, c)
  local s = self.lines[l]
  local n = len(s)
  local function at(i) return ui.sub(s, i + 1, i + 1) end
  local a = c
  if a >= n or not isWord(at(a)) then
    if a > 0 and isWord(at(a - 1)) then a = a - 1 else return nil end
  end
  local z = a
  while a > 0 and isWord(at(a - 1)) do a = a - 1 end
  while z < n and isWord(at(z)) do z = z + 1 end
  return a, z
end

-- The column of the next (dir 1) or previous (dir -1) word boundary.
function B:wordMove(l, c, dir)
  local s = self.lines[l]
  local n = len(s)
  local function at(i) return ui.sub(s, i + 1, i + 1) end
  if dir > 0 then
    while c < n and not isWord(at(c)) do c = c + 1 end
    while c < n and isWord(at(c)) do c = c + 1 end
  else
    while c > 0 and not isWord(at(c - 1)) do c = c - 1 end
    while c > 0 and isWord(at(c - 1)) do c = c - 1 end
  end
  return c
end

-- ------------------------------------------------------------------ search

-- Next occurrence of needle (plain text, any case) after (l, c), wrapping
-- around (backwards with dir -1). Returns l, c1, c2 or nil.
function B:find(needle, l, c, dir)
  if needle == "" then return nil end
  needle = needle:lower()
  local n = #self.lines
  dir = dir or 1
  for k = 0, n do
    local ln = (l - 1 + k * dir) % n + 1
    local s = self.lines[ln]:lower()
    if dir > 0 then
      local from = k == 0 and offset(s, c) or 1
      local a, z = s:find(needle, from, true)
      if a then return ln, len(s:sub(1, a - 1)), len(s:sub(1, z)) end
    else
      local limit = k == 0 and offset(s, c) - 1 or #s
      local best
      local i = 1
      while true do
        local a, z = s:find(needle, i, true)
        if not a or z > limit then break end
        best = {a, z}
        i = a + 1
      end
      if best then return ln, len(s:sub(1, best[1] - 1)), len(s:sub(1, best[2])) end
    end
  end
  return nil
end

-- Replaces every occurrence (plain, any case); returns how many.
function B:replaceAll(needle, with)
  if needle == "" then return 0 end
  self:begin(nil)
  local count = 0
  local lower = needle:lower()
  for l = 1, #self.lines do
    local s = self.lines[l]
    local i = 1
    while true do
      local a, z = s:lower():find(lower, i, true)
      if not a then break end
      local c1, c2 = len(s:sub(1, a - 1)), len(s:sub(1, z))
      self:delete(l, c1, l, c2)
      self:insert(l, c1, with)
      s = self.lines[l]
      i = a + #with
      count = count + 1
    end
  end
  self.lastKind = nil
  return count
end

-- ------------------------------------------------------------------ highlighting

local function diffAttrs(s, base)
  local c = s:sub(1, 1)
  local fg = c == "+" and 0x0A or c == "-" and 0x0C or c == "@" and 0x0B or nil
  if not fg then return string.rep(string.char(base), #s) end
  return string.rep(string.char((base & 0xF0) | fg), #s)
end

-- Attributes of line l (a byte per byte), on background base.
function B:attrs(l, base)
  base = base or 0x07
  local lang = self.lang
  if lang == "diff" then return diffAttrs(self.lines[l], base) end
  if lang ~= "lua" and lang ~= "sh" then return nil end
  if l <= self.hlDone and self.hlAttr[l] then return self.hlAttr[l] end
  local fn = hl[lang]
  for i = self.hlDone + 1, l do
    local a, st = fn(self.lines[i], self.hlState[i] or 0, base)
    self.hlAttr[i], self.hlState[i + 1] = a, st
  end
  self.hlDone = l
  return self.hlAttr[l]
end

return M
