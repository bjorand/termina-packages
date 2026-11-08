-- code.ui: colors, text measuring and drawing helpers shared by the panes.
-- Text is UTF-8; one character takes one cell (the screen is CP437).
local host = require "code.host"
local term, key, sys = host.term, host.key, host.sys

local M = {}

-- Attributes: background * 16 + foreground.
M.TEXT = 0x07
M.DIM = 0x08
M.BRIGHT = 0x0F
M.LINENO = 0x08
M.LINENO_CUR = 0x07
M.SEL_BG = 0x10             -- selection: the text's color on blue
M.MATCH_BG = 0x60           -- search match
M.TAB = 0x08
M.TAB_ACTIVE = 0x70
M.TAB_MODIFIED = 0x0E
M.STATUS = 0x1F
M.STATUS_ERR = 0x4F
M.HEADER = 0x08
M.HEADER_FOCUS = 0x0F
M.FRAME = 0x08
M.ITEM = 0x07
M.ITEM_SEL = 0x1F           -- selected row of the focused pane
M.ITEM_SEL_DIM = 0x0F       -- selected row of another pane
M.DIR = 0x0B
M.ERROR = 0x0C
M.WARN = 0x0E
M.ADDED = 0x0A
M.MODIFIED = 0x0E
M.DELETED = 0x0C
M.POPUP = 0x70
M.POPUP_SEL = 0x1F
M.POPUP_DIM = 0x78
M.TRACK = 0x08              -- scroll bars
M.THUMB = 0x07

-- Characters (CP437).
M.VBAR = "\u{2502}"
M.HBAR = "\u{2500}"
M.TEE_DOWN = "\u{252C}"
M.TEE_UP = "\u{2534}"
M.TEE_RIGHT = "\u{251C}"
M.TEE_LEFT = "\u{2524}"
M.CROSS = "\u{253C}"
M.CORNER_TL, M.CORNER_TR = "\u{250C}", "\u{2510}"
M.CORNER_BL, M.CORNER_BR = "\u{2514}", "\u{2518}"
M.OPEN = "\u{25BC}"         -- expanded folder
M.CLOSED = "\u{25BA}"       -- collapsed folder
M.DOT = "\u{2022}"          -- modified file
M.FUNC = "\u{0192}"
M.BLOCK = "\u{258C}"        -- gutter mark
M.LOWER = "\u{2584}"        -- gutter: lines removed below
M.UP, M.DOWN = "\u{2191}", "\u{2193}"
M.TRACK_CH = "\u{2591}"
M.THUMB_CH = "\u{2588}"

-- ------------------------------------------------------------------ text

local find = string.find

function M.ascii(s)
  return not find(s, "[\128-\255]")
end

-- Characters in s.
function M.len(s)
  if M.ascii(s) then return #s end
  return utf8.len(s) or #s
end

-- Byte offset of character c (0-based) in s; #s + 1 past the end.
function M.offset(s, c)
  if c <= 0 then return 1 end
  if M.ascii(s) then return c < #s and c + 1 or #s + 1 end
  return utf8.offset(s, c + 1) or #s + 1
end

-- Characters i to j (1-based, inclusive) of s.
function M.sub(s, i, j)
  if M.ascii(s) then return s:sub(i, j) end
  local n = M.len(s)
  j = j or n
  if j < 0 then j = n + j + 1 end
  if i < 1 then i = 1 end
  if j < i then return "" end
  return s:sub(M.offset(s, i - 1), M.offset(s, j) - 1)
end

-- s cut or padded with spaces to n characters.
function M.fit(s, n)
  if n <= 0 then return "" end
  local w = M.len(s)
  if w > n then return M.sub(s, 1, n) end
  return s .. string.rep(" ", n - w)
end

-- s cut to n characters, keeping its end ("...name.lua").
function M.tail(s, n)
  local w = M.len(s)
  if w <= n then return s end
  return ".." .. M.sub(s, w - n + 3)
end

-- ------------------------------------------------------------------ drawing

-- s in attr, exactly w cells (cut or padded).
function M.put(x, y, s, attr, w)
  if w then
    if w <= 0 then return 0 end
    return term.putattr(x, y, s, string.char(attr), w, attr)
  end
  return term.putattr(x, y, s, string.char(attr))
end

function M.hline(x, y, w, attr, ch)
  if w > 0 then term.putattr(x, y, string.rep(ch or M.HBAR, w), string.char(attr)) end
end

function M.vline(x, y, h, attr, ch)
  for i = 0, h - 1 do term.cell(x, y + i, ch or M.VBAR, attr) end
end

function M.fill(x, y, w, h, attr)
  local blank = string.rep(" ", w)
  for i = 0, h - 1 do term.putattr(x, y + i, blank, string.char(attr)) end
end

-- A frame with an optional title on its top line.
function M.box(x, y, w, h, attr, title)
  M.put(x, y, M.CORNER_TL .. string.rep(M.HBAR, w - 2) .. M.CORNER_TR, attr)
  for i = 1, h - 2 do
    term.cell(x, y + i, M.VBAR, attr)
    term.cell(x + w - 1, y + i, M.VBAR, attr)
  end
  M.put(x, y + h - 1, M.CORNER_BL .. string.rep(M.HBAR, w - 2) .. M.CORNER_BR, attr)
  if title and title ~= "" then M.put(x + 2, y, " " .. M.fit(title, math.min(M.len(title), w - 6)) .. " ", attr) end
end

-- A vertical scroll bar of h cells at (x, y), for a view showing `visible`
-- items out of `total`, the first one being item `first` (from 1). Without
-- anything to scroll, an empty column.
function M.scrollbar(x, y, h, total, first, visible)
  if total <= visible then
    for i = 0, h - 1 do term.cell(x, y + i, " ", M.TEXT) end
    return
  end
  local size = math.max(1, h * visible // total)
  local pos = (first - 1) * (h - size) // math.max(1, total - visible)
  pos = math.max(0, math.min(h - size, pos))
  for i = 0, h - 1 do
    if i >= pos and i < pos + size then term.cell(x, y + i, M.THUMB_CH, M.THUMB)
    else term.cell(x, y + i, M.TRACK_CH, M.TRACK) end
  end
end

-- The first item to show when the bar of M.scrollbar is clicked or dragged
-- at row y: the thumb is centered there.
function M.scrollTo(y, y0, h, total, visible)
  if total <= visible then return 1 end
  local size = math.max(1, h * visible // total)
  local span = math.max(1, h - size)
  local pos = math.max(0, math.min(span, y - y0 - size // 2))
  return 1 + (pos * (total - visible) + span // 2) // span
end

-- Whether (x, y) is inside the rectangle r = {x, y, w, h}.
function M.inside(r, x, y)
  return r and r.w > 0 and r.h > 0 and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- ------------------------------------------------------------------ input

-- Ctrl+letter arrives as a key event; a char event without modifiers is text.
function M.isKey(e, name, mods)
  if e.type ~= "key" or e.key ~= name then return false end
  mods = mods or ""
  return not e.ctrl == not mods:find("c") and not e.shift == not mods:find("s") and
      not e.alt == not mods:find("a")
end

-- Clicks: counts quick clicks on the same cell (double, triple click).
local lastClick = {t = 0, x = -1, y = -1, n = 0}
function M.clickCount(e)
  local now = sys.millis()
  if now - lastClick.t < 400 and e.x == lastClick.x and e.y == lastClick.y then
    lastClick.n = lastClick.n % 3 + 1
  else
    lastClick.n = 1
  end
  lastClick.t, lastClick.x, lastClick.y = now, e.x, e.y
  return lastClick.n
end

-- Waits for the next event, keeping the other processes running.
function M.waitEvent()
  while true do
    local e = key.poll()
    if e then return e end
    sys.sleep(15)
  end
end

return M
