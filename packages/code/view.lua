-- code.view: draws a buffer in a rectangle of the screen (line numbers, git
-- marks, diagnostics, selection) and turns keys and the mouse into edits.
local term, sys = termina.term, termina.sys
local ui = require "code.ui"

local M = {}

local WHEEL_LINES = 3

-- Width of the gutter: line numbers, then a git mark column.
local function gutterWidth(b)
  return math.max(3, #tostring(#b.lines)) + 2
end
M.gutterWidth = gutterWidth

-- Brings the cursor back into the view when it moved or the text changed;
-- otherwise (the wheel) the view stays where it was scrolled.
function M.scroll(b, r)
  local tw = r.w - gutterWidth(b) - 1
  if b.cy ~= b.seenCy or b.cx ~= b.seenCx or b.changes ~= b.seenChanges then
    b.seenCy, b.seenCx, b.seenChanges = b.cy, b.cx, b.changes
    if b.cy < b.top then b.top = b.cy end
    if b.cy >= b.top + r.h then b.top = b.cy - r.h + 1 end
    if b.cx < b.left then b.left = math.max(0, b.cx - 4) end
    if b.cx >= b.left + tw then b.left = b.cx - tw + 5 end
  end
  b.top = math.max(1, math.min(b.top, math.max(1, #b.lines - r.h + 1)))
end

-- Centers line l in the view (after a jump).
function M.center(b, r, l)
  b.top = math.max(1, l - r.h // 2)
end

local function withBg(attrs, from, to, bg)
  -- bytes from..to (1-based, inclusive) of attrs on background bg
  if from > to then return attrs end
  local mid = attrs:sub(from, to):gsub(".", function(c) return string.char((c:byte() & 0x0F) | bg) end)
  return attrs:sub(1, from - 1) .. mid .. attrs:sub(to + 1)
end

-- Draws buffer b in r = {x, y, w, h}, its scroll bar in the last column.
-- find: text to mark in the view.
function M.draw(b, r, focused, find)
  local gw = gutterWidth(b)
  local tx, tw = r.x + gw, r.w - gw - 1
  local sl1, sc1, sl2, sc2 = b:selection()
  local needle = find and find ~= "" and find:lower() or nil
  for row = 0, r.h - 1 do
    local l = b.top + row
    local y = r.y + row
    local s = b.lines[l]
    if not s then
      ui.put(r.x, y, "", ui.TEXT, r.w - 1)
    else
      -- gutter
      local diag = b.diags[l]
      local numAttr = diag and (diag.warn and 0x6E or 0x4F) or (l == b.cy and ui.LINENO_CUR or ui.LINENO)
      ui.put(r.x, y, string.format("%" .. (gw - 2) .. "d", l), numAttr)
      local mark = b.marks[l]
      local mch, mat = " ", ui.TEXT
      if mark == "+" then mch, mat = ui.BLOCK, ui.ADDED
      elseif mark == "~" then mch, mat = ui.BLOCK, ui.MODIFIED
      elseif mark == "-" then mch, mat = ui.LOWER, ui.DELETED end
      if l == 1 and b.marks[0] == "-" and not mark then mch, mat = "\u{2580}", ui.DELETED end
      term.cell(r.x + gw - 2, y, mch, mat)
      term.cell(r.x + gw - 1, y, " ", ui.TEXT)
      -- text
      local a = ui.offset(s, b.left)
      local z = ui.offset(s, b.left + tw) - 1
      local text = s:sub(a, z)
      local attrs = b:attrs(l, ui.TEXT)
      attrs = attrs and attrs:sub(a, z) or string.rep(string.char(ui.TEXT), #text)
      if needle then
        local low = text:lower()
        local i = 1
        while true do
          local p, q = low:find(needle, i, true)
          if not p then break end
          attrs = withBg(attrs, p, q, ui.MATCH_BG)
          i = q + 1
        end
      end
      if sl1 and l >= sl1 and l <= sl2 then
        local from = l == sl1 and sc1 or 0
        local to = l == sl2 and sc2 or math.huge
        from, to = math.max(from, b.left), math.min(to, b.left + tw)
        if from < to then
          local p = ui.offset(s, from) - a + 1
          local q = ui.offset(s, to) - a
          attrs = withBg(attrs, p, q, ui.SEL_BG)
        end
        -- a selected line break shows as one selected cell
        local n = ui.len(text)
        if l < sl2 and to == math.huge and n < tw then
          text = text .. " "
          attrs = attrs .. string.char(ui.SEL_BG | 0x07)
        end
      end
      term.putattr(tx, y, text, attrs, tw, ui.TEXT)
    end
  end
  ui.scrollbar(r.x + r.w - 1, r.y, r.h, #b.lines, b.top, r.h)
  if focused then
    local cy, cx = b.cy - b.top, b.cx - b.left
    if cy >= 0 and cy < r.h and cx >= 0 and cx < tw then
      term.cursor(tx + cx, r.y + cy)
      term.showcursor(true)
    else
      term.showcursor(false)
    end
  end
end

-- The text position under the screen cell (x, y).
function M.posAt(b, r, x, y)
  local l = math.min(#b.lines, b.top + (y - r.y))
  local c = b.left + x - (r.x + gutterWidth(b))
  return math.max(1, l), math.max(0, math.min(c, b:lineLen(math.max(1, l))))
end

-- ------------------------------------------------------------------ keys

local function copy(b)
  local t = b:selectedText()
  if not t then t = b.lines[b.cy] .. "\n" end  -- no selection: the whole line
  sys.setclipboard(t)
end

local function cut(b)
  if b.readonly then return copy(b) end
  if b:selectedText() then
    copy(b)
    b:begin(nil)
    b:deleteSelection()
  else
    sys.setclipboard(b.lines[b.cy] .. "\n")
    b:begin(nil)
    if b.cy < #b.lines then b:delete(b.cy, 0, b.cy + 1, 0)
    else b:delete(b.cy, 0, b.cy, b:lineLen(b.cy)) end
    b.cx = 0
  end
  b.want = b.cx
end

local function paste(b)
  local t = sys.clipboard()
  if t == "" then return end
  t = t:gsub("\r\n", "\n"):gsub("\t", "    ")
  b:type(t, nil)
  b.lastKind = nil
end
M.copy, M.cut, M.paste = copy, cut, paste

-- Indents (dir 1) or outdents (dir -1) the lines of the selection, or the
-- cursor's line.
local function indentLines(b, dir)
  local l1, _, l2, c2 = b:selection()
  if not l1 then l1, l2 = b.cy, b.cy
  elseif c2 == 0 and l2 > l1 then l2 = l2 - 1 end
  b:begin(nil)
  for l = l1, l2 do
    if dir > 0 then
      b:insert(l, 0, "  ")
    else
      local n = #b:indent(l)
      if n > 0 then b:delete(l, 0, l, math.min(2, n)) end
    end
  end
  b.lastKind = nil
  if b.ay then b.ax = 0 end
  b.cx = math.max(0, math.min(b.cx + (dir > 0 and 2 or -2), b:lineLen(b.cy)))
end

-- Comments or uncomments the lines (-- for Lua, # for sh).
local function toggleComment(b)
  local mark = b.lang == "sh" and "# " or "-- "
  local l1, _, l2, c2 = b:selection()
  if not l1 then l1, l2 = b.cy, b.cy
  elseif c2 == 0 and l2 > l1 then l2 = l2 - 1 end
  local all = true
  for l = l1, l2 do
    local s = b.lines[l]
    if s:match("%S") and not s:match("^%s*" .. mark:sub(1, -2):gsub("%-", "%%-")) then all = false end
  end
  b:begin(nil)
  for l = l1, l2 do
    local s = b.lines[l]
    local ind = #s:match("^ *")
    if all then
      local bare = mark:sub(1, -2)
      if s:sub(ind + 1, ind + #mark) == mark then b:delete(l, ind, l, ind + #mark)
      elseif s:sub(ind + 1, ind + #bare) == bare then b:delete(l, ind, l, ind + #bare) end
    elseif s:match("%S") then
      b:insert(l, ind, mark)
    end
  end
  b.lastKind = nil
  b.cx = math.min(b.cx, b:lineLen(b.cy))
end

-- Moves the cursor's line (or the selected lines) up or down.
local function moveLines(b, dir)
  local l1, _, l2, c2 = b:selection()
  if not l1 then l1, l2 = b.cy, b.cy
  elseif c2 == 0 and l2 > l1 then l2 = l2 - 1 end
  if (dir < 0 and l1 == 1) or (dir > 0 and l2 == #b.lines) then return end
  b:begin(nil)
  if dir < 0 then
    local above = b.lines[l1 - 1]
    b:delete(l1 - 1, 0, l1, 0)
    b:insert(l2 - 1, b:lineLen(l2 - 1), "\n" .. above)
  else
    local below = b.lines[l2 + 1]
    b:delete(l2, b:lineLen(l2), l2 + 1, b:lineLen(l2 + 1))
    b:insert(l1, 0, below .. "\n")
  end
  b.lastKind = nil
  b.cy = b.cy + dir
  if b.ay then b.ay = b.ay + dir end
end

-- Handles a key or char event for the editor view; returns true if it
-- was one of its keys.
function M.key(b, e, r)
  local ro = b.readonly
  if e.type == "char" then
    if ro then return true end
    local ch = e.ch
    b:type(ch, ch:match("[%w_]") and "type" or "punct")
    return true
  end
  if e.type ~= "key" then return false end
  local k, sel = e.key, e.shift
  local ctrl, alt = e.ctrl, e.alt
  local page = math.max(1, r.h - 1)
  if k == "left" and not alt then
    if not sel and b:selection() and not ctrl then
      local l1, c1 = b:selection()
      b:moveTo(l1, c1)
    elseif ctrl then
      b:moveTo(b.cy, b:wordMove(b.cy, b.cx, -1), sel)
    elseif b.cx > 0 then b:moveTo(b.cy, b.cx - 1, sel)
    elseif b.cy > 1 then b:moveTo(b.cy - 1, b:lineLen(b.cy - 1), sel) end
    b.want = b.cx
  elseif k == "right" and not alt then
    if not sel and b:selection() and not ctrl then
      local _, _, l2, c2 = b:selection()
      b:moveTo(l2, c2)
    elseif ctrl then
      b:moveTo(b.cy, b:wordMove(b.cy, b.cx, 1), sel)
    elseif b.cx < b:lineLen(b.cy) then b:moveTo(b.cy, b.cx + 1, sel)
    elseif b.cy < #b.lines then b:moveTo(b.cy + 1, 0, sel) end
    b.want = b.cx
  elseif (k == "up" or k == "down") and alt and not ctrl then
    if not ro then moveLines(b, k == "up" and -1 or 1) end
  elseif k == "up" and ctrl then
    b.top = math.max(1, b.top - 1)
    return true
  elseif k == "down" and ctrl then
    b.top = math.min(#b.lines, b.top + 1)
    return true
  elseif k == "up" then b:moveTo(b.cy - 1, b.want, sel)
  elseif k == "down" then b:moveTo(b.cy + 1, b.want, sel)
  elseif k == "pgup" and not ctrl then
    b.top = math.max(1, b.top - page)
    b:moveTo(b.cy - page, b.want, sel)
  elseif k == "pgdn" and not ctrl then
    b.top = b.top + page
    b:moveTo(b.cy + page, b.want, sel)
  elseif k == "home" then
    if ctrl then b:moveTo(1, 0, sel)
    else
      local ind = #b:indent(b.cy)
      b:moveTo(b.cy, b.cx == ind and 0 or ind, sel)  -- first the indentation, then column 0
    end
    b.want = b.cx
  elseif k == "end" then
    if ctrl then b:moveTo(#b.lines, b:lineLen(#b.lines), sel)
    else b:moveTo(b.cy, b:lineLen(b.cy), sel) end
    b.want = b.cx
  elseif ro then
    return not ctrl and k ~= "esc" and k ~= "tab" and not k:match("^f%d")
  elseif k == "enter" and not ctrl then
    local ind = b:indent(b.cy)
    local before = b.lines[b.cy]:sub(1, ui.offset(b.lines[b.cy], b.cx) - 1)
    if b.lang == "lua" and (before:match("[%(%{%[]%s*$") or before:match("%f[%w]then%s*$") or
        before:match("%f[%w]do%s*$") or before:match("%f[%w]else%s*$") or
        before:match("function%s*[%w_.:]*%s*%(.-%)%s*$") or before:match("%f[%w]repeat%s*$")) then
      ind = ind .. "  "
    end
    b:type("\n" .. ind, nil)
    b.lastKind = nil
  elseif k == "backspace" then
    if not b:selection() then
      b:begin("erase")
      if b.cx > 0 then
        -- in the indentation, back to the previous multiple of 2
        local ind = #b:indent(b.cy)
        local n = (b.cx <= ind and b.cx % 2 == 0 and b.cx >= 2) and 2 or 1
        b:delete(b.cy, b.cx - n, b.cy, b.cx)
        b.cx = b.cx - n
      elseif b.cy > 1 then
        local c = b:lineLen(b.cy - 1)
        b:delete(b.cy - 1, c, b.cy, 0)
        b.cy, b.cx = b.cy - 1, c
      end
    else
      b:begin(nil)
      b:deleteSelection()
    end
    b.want = b.cx
  elseif k == "delete" then
    if not b:selection() then
      b:begin("delete")
      if b.cx < b:lineLen(b.cy) then b:delete(b.cy, b.cx, b.cy, b.cx + 1)
      elseif b.cy < #b.lines then b:delete(b.cy, b.cx, b.cy + 1, 0) end
    else
      b:begin(nil)
      b:deleteSelection()
    end
  elseif k == "tab" and not ctrl then
    local l1, _, l2 = b:selection()
    if sel or (l1 and l2 > l1) then indentLines(b, sel and -1 or 1)
    else b:type(string.rep(" ", 2 - b.cx % 2), "type") end
  elseif ctrl and k == "/" then
    toggleComment(b)
  elseif ctrl and k == "d" then  -- duplicate the line
    b:begin(nil)
    b:insert(b.cy, b:lineLen(b.cy), "\n" .. b.lines[b.cy])
    b.cy = b.cy + 1
    b.lastKind = nil
  elseif ctrl and k == "k" and sel then  -- delete the line
    b:begin(nil)
    if b.cy < #b.lines then b:delete(b.cy, 0, b.cy + 1, 0)
    elseif b.cy > 1 then b:delete(b.cy - 1, b:lineLen(b.cy - 1), b.cy, b:lineLen(b.cy)); b.cy = b.cy - 1
    else b:delete(1, 0, 1, b:lineLen(1)) end
    b.cx = math.min(b.cx, b:lineLen(b.cy))
    b.lastKind = nil
  else
    return false
  end
  if k ~= "up" and k ~= "down" and k ~= "pgup" and k ~= "pgdn" then b.want = b.cx end
  return true
end

-- Clipboard and selection keys, shared with read-only buffers.
function M.editKey(b, e)
  if e.type ~= "key" or not e.ctrl or e.alt then return false end
  local k = e.key
  if k == "c" then copy(b)
  elseif k == "x" then cut(b)
  elseif k == "v" then if not b.readonly then paste(b) end
  elseif k == "a" then b:selectAll()
  elseif k == "z" then if not b.readonly then b:undo() end
  elseif k == "y" then if not b.readonly then b:redo() end
  else return false end
  return true
end

-- ------------------------------------------------------------------ mouse

local drag     -- the buffer being selected with the mouse
local dragBar  -- the buffer whose scroll bar is being dragged

-- Handles a mouse event inside the view; returns true if it used it.
function M.mouse(b, e, r)
  if e.type == "wheel" then
    b.top = math.max(1, math.min(#b.lines, b.top - e.n * WHEEL_LINES))
    return true
  end
  if e.type == "mouse" and e.button == 0 then
    if not e.down then
      drag, dragBar = nil, nil
      return true
    end
    if e.x == r.x + r.w - 1 then  -- the scroll bar
      dragBar = b
      b.top = ui.scrollTo(e.y, r.y, r.h, #b.lines, r.h)
      return true
    end
    local l, c = M.posAt(b, r, e.x, e.y)
    local n = ui.clickCount(e)
    if n == 2 then
      local a, z = b:wordAt(l, c)
      if a then
        b.ay, b.ax, b.cy, b.cx = l, a, l, z
      end
    elseif n == 3 then
      b.ay, b.ax = l, 0
      if l < #b.lines then b.cy, b.cx = l + 1, 0 else b.cy, b.cx = l, b:lineLen(l) end
    else
      b:moveTo(l, c)
      drag = b
    end
    b.want, b.lastKind = b.cx, nil
    return true
  end
  if e.type == "mouse" and e.button == 2 and e.down then
    if not b.readonly then
      local l, c = M.posAt(b, r, e.x, e.y)
      b:moveTo(l, c)
      paste(b)
    end
    return true
  end
  if e.type == "move" and dragBar == b and e.buttons & 1 ~= 0 then
    b.top = ui.scrollTo(e.y, r.y, r.h, #b.lines, r.h)
    return true
  end
  if e.type == "move" and drag == b and e.buttons & 1 ~= 0 then
    local y = e.y
    if y < r.y then b.top = math.max(1, b.top - 1); y = r.y
    elseif y >= r.y + r.h then b.top = math.min(#b.lines, b.top + 1); y = r.y + r.h - 1 end
    local l, c = M.posAt(b, r, e.x, y)
    b:moveTo(l, c, true)
    b.want = b.cx
    return true
  end
  return false
end

function M.dragging()
  return drag ~= nil
end

function M.stopDrag()
  drag, dragBar = nil, nil
end

return M
