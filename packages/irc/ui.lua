-- irc.ui: the screen. Row 0 is the system status bar. Two layouts:
--
--   wide (100 columns or more): one row per message with the time and the
--   nick in columns, the nick list on the right.
--   tall (portrait, under 100 columns): the topic in full, messages
--   grouped under a "nick time" header, the window bar and the input line
--   on several rows.
--
-- In both, channels have the nick list on the right (Alt+N hides it), as
-- narrow as the nicks allow. M.picker, when set, shows the list of windows
-- in place of the messages (Alt+W).
local proto = require "irc.proto"
local model = require "irc.model"
local input = require "irc.input"
local term = termina.term

local M = {
  mode = "auto",     -- "auto", "tall" or "wide"
  showNicks = true,  -- the nick list column (Alt+N)
  picker = nil,      -- {kind = "windows", sel}: the window list is open
  tabs = {},         -- {y, x0, x1, win} of the window bar, for the mouse
  nickCells = {},    -- {y, x0, x1, nick} of the nick list column
  pickRows = {},     -- y -> item (a window, or a nick {nick, pre}) of the list
  msgRows = 20,      -- rows of messages on screen
}

-- Attributes: background * 16 + foreground.
local TITLE, TITLE_DIM, TITLE_WARN = 0x1F, 0x1B, 0x1E
local BAR, BAR_DIM, BAR_EVENT, BAR_MSG, BAR_HILITE, BAR_ACTIVE = 0x17, 0x17, 0x1B, 0x1F, 0x1D, 0x71
local TEXT, DIM, BRIGHT, ERR = 0x07, 0x08, 0x0F, 0x0C
local TIME, SEP = 0x08, 0x08
local HILITE_NICK = 0x5F
local ACTION = 0x0D
local PROMPT = 0x0B
local SELECTED = 0x70
local NICK_COLORS = {0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x09, 0x02, 0x03, 0x05, 0x06, 0x04}
local PREFIX_COLORS = {["~"] = 0x0C, ["&"] = 0x0C, ["@"] = 0x0A, ["%"] = 0x0D, ["+"] = 0x0E}

local VBAR, HBAR = "\u{2502}", "\u{2500}"
local ARROW_IN, ARROW_OUT, DOT = "\u{2192}", "\u{2190}", "\u{00B7}"
local NICKW = 9        -- wide: width of the nick column
local LISTW = 14       -- width of the nick list at most
local TOPIC_ROWS = 2   -- tall: rows of topic at most
local BAR_ROWS = 3     -- tall: rows of the window bar at most
local INPUT_ROWS = 3   -- tall: rows of the input line at most

local function nickColor(nick)
  local h = 0
  for i = 1, #nick do h = (h * 31 + nick:byte(i)) & 0xFFFFFF end
  return NICK_COLORS[h % #NICK_COLORS + 1]
end
M.nickColor = nickColor

function M.tall()
  if M.mode == "tall" then return true end
  if M.mode == "wide" then return false end
  return term.cols() < 100
end

-- ------------------------------------------------------------------ rows

-- A row under construction: text and one attribute byte per text byte.
local Row = {}
Row.__index = Row

local function row()
  return setmetatable({t = {}, a = {}, w = 0}, Row)
end

function Row:add(s, attr)
  self.t[#self.t + 1] = s
  self.a[#self.a + 1] = string.rep(string.char(attr), #s)
  self.w = self.w + input.len(s)
  return self
end

function Row:addA(s, attrs)
  self.t[#self.t + 1] = s
  self.a[#self.a + 1] = attrs
  self.w = self.w + input.len(s)
  return self
end

-- Exactly w cells: cut, or padded with spaces in attr.
function Row:fit(w, attr)
  if self.w > w then
    local t, a = table.concat(self.t), table.concat(self.a)
    local b = input.offset(t, w + 1)
    self.t, self.a, self.w = {t:sub(1, b - 1)}, {a:sub(1, b - 1)}, w
  elseif self.w < w then
    self:add(string.rep(" ", w - self.w), attr)
  end
  return self
end

function Row:text() return table.concat(self.t) end
function Row:attrs() return table.concat(self.a) end

function Row:copy()
  return setmetatable({t = {table.concat(self.t)}, a = {table.concat(self.a)}, w = self.w}, Row)
end

-- Cut s to w characters, with "+" when it was longer.
local function cut(s, w)
  if w < 1 then return "" end
  if input.len(s) <= w then return s end
  return input.sub(s, 1, w - 1) .. "+"
end

-- Text that is not valid UTF-8 is taken as Latin-1; control characters
-- other than the mIRC formatting codes go.
function M.clean(s)
  if not utf8.len(s) then
    s = s:gsub("[\128-\255]", function(c) return utf8.char(c:byte()) end)
  end
  return (s:gsub("\t", " "):gsub("[%z\1\4-\14\16\18-\21\23-\28]", ""))
end

-- wrap(t, a, w [, wnext]) -> list of {t, a}: the first of w cells at most,
-- the others of wnext, cut at spaces.
local function wrap(t, a, w, wnext)
  local rows = {}
  wnext = wnext or w
  while true do
    if w < 1 then w = 1 end
    local n = utf8.len(t) or #t
    if n <= w then
      rows[#rows + 1] = {t, a}
      return rows
    end
    local b = utf8.offset(t, w + 1) or (w + 1)
    local sp = t:sub(1, b):match(".*() ")
    if sp and sp > 1 then
      rows[#rows + 1] = {t:sub(1, sp - 1), a:sub(1, sp - 1)}
      t, a = t:sub(sp + 1), a:sub(sp + 1)
    else
      rows[#rows + 1] = {t:sub(1, b - 1), a:sub(1, b - 1)}
      t, a = t:sub(b), a:sub(b)
    end
    w = wnext
  end
end

-- Text after a lead (a Row), wrapped in w cells, the next rows indented.
local function lead(r, text, attr, w, indent)
  local t, a = proto.format(M.clean(text), attr)
  local rows = {}
  for i, part in ipairs(wrap(t, a, w - r.w, w - indent)) do
    local x = i == 1 and r or row():add(string.rep(" ", indent), TEXT)
    x:addA(part[1], part[2])
    rows[i] = x
  end
  return rows
end

-- ------------------------------------------------------- message lines

local SAID_KINDS = {msg = true, self = true, notice = true}

-- The symbol and colors of a line that is not said by someone.
local EVENTS = {
  join = {ARROW_IN, 0x0A, DIM},
  part = {ARROW_OUT, 0x04, DIM},
  error = {"!", ERR, ERR},
  event = {DOT, 0x03, TEXT},
}

-- Wide: "HH:MM     nick | text", the next rows under the text.
local function wideRows(line, w, showTime)
  local nick, nickAttr, text, textAttr = "", TEXT, line.text or "", TEXT
  local k = line.kind
  if k == "msg" or k == "self" then
    nick = line.nick or "?"
    nickAttr = line.hl and HILITE_NICK or (k == "self" and BRIGHT or nickColor(nick))
    textAttr = line.hl and BRIGHT or TEXT
  elseif k == "action" then
    nick, nickAttr = "*", ACTION
    text = (line.nick or "?") .. " " .. text
    textAttr = line.hl and BRIGHT or ACTION
  elseif k == "notice" then
    nick, nickAttr = "-" .. (line.nick or "?") .. "-", ACTION
  elseif k == "join" then nick, nickAttr, textAttr = "-->", 0x0A, DIM
  elseif k == "part" then nick, nickAttr, textAttr = "<--", 0x04, DIM
  elseif k == "error" then nick, nickAttr, textAttr = "!!", ERR, line.hl and BRIGHT or ERR
  else nick, nickAttr, textAttr = "--", 0x03, line.hl and BRIGHT or TEXT
  end
  nick = cut(nick, NICKW)
  local head = row()
  if showTime then head:add(line.time .. " ", TIME) end
  head:add(string.rep(" ", NICKW - input.len(nick)), TEXT):add(nick, nickAttr):add(" " .. VBAR .. " ", SEP)
  local hw = head.w
  local t, a = proto.format(M.clean(text), textAttr)
  local rows = {}
  for i, part in ipairs(wrap(t, a, w - hw)) do
    local r
    if i == 1 then r = head
    else r = row():add(string.rep(" ", hw - 2), TEXT):add(VBAR .. " ", SEP) end
    r:addA(part[1], part[2])
    rows[i] = r
  end
  return rows
end

-- Tall: a "nick  HH:MM" header when someone starts talking, then the text
-- over the whole width less an indent of 2; events on one row with a
-- symbol.
local function tallRows(line, w)
  local k = line.kind
  local rows = {}
  if k == "msg" or k == "self" or k == "notice" then
    if not line.cont then
      if line.gap then rows[#rows + 1] = row() end
      local nick = line.nick or "?"
      local attr = line.hl and HILITE_NICK or k == "self" and BRIGHT or k == "notice" and ACTION or nickColor(nick)
      if k == "notice" then nick = "-" .. nick .. "-" end
      rows[#rows + 1] = row():add(cut(nick, w - 7), attr):add(" " .. line.time, TIME)
    end
    local textAttr = line.hl and BRIGHT or TEXT
    for _, r in ipairs(lead(row():add("  ", TEXT), line.text or "", textAttr, w, 2)) do
      rows[#rows + 1] = r
    end
  elseif k == "action" then
    local r = row():add("* ", ACTION):add(line.nick or "?", line.hl and HILITE_NICK or nickColor(line.nick or "?")):add(" ", TEXT)
    rows = lead(r, line.text or "", line.hl and BRIGHT or ACTION, w, 2)
  else
    local e = EVENTS[k] or EVENTS.event
    rows = lead(row():add(e[1] .. " ", e[2]), line.text or "", line.hl and BRIGHT or e[3], w, 2)
  end
  if line.gap and not SAID_KINDS[k] then table.insert(rows, 1, row()) end
  return rows
end

-- The rows of a line, kept with it until the width or layout changes.
local function lineRows(line, w, tall, showTime)
  local key = (tall and "t" or showTime and "w" or "n") .. w
  if line.cacheW == key then return line.cache end
  local rows = tall and tallRows(line, w) or wideRows(line, w, showTime)
  line.cacheW, line.cache = key, rows
  return rows
end

-- The message rows of win that fit in h rows, scrolled by win.scroll:
-- list from the bottom row up.
local function messageRows(win, w, h, tall, showTime)
  local out = {}
  local need = h + win.scroll
  for i = #win.lines, 1, -1 do
    local lr = lineRows(win.lines[i], w, tall, showTime)
    for j = #lr, 1, -1 do
      out[#out + 1] = lr[j]
      if #out >= need then break end
    end
    if #out >= need then break end
  end
  if #out < need then win.scroll = math.max(0, #out - h) end
  return out
end

-- ---------------------------------------------------------------- drawing

local shown = {} -- y -> what is on that row now
local lastCols, lastRows

function M.invalidate() shown = {} end

local function put(y, r, w, pad)
  r:fit(w, pad)
  local t, a = r:text(), r:attrs()
  local k = t .. "\0" .. a
  if shown[y] == k then return end
  shown[y] = k
  term.putattr(0, y, t, a, w, pad)
end

-- The title: the window's name, then (tall) what is known about it on the
-- next rows. Returns a list of Rows.
local function titleRows(win, cols, tall)
  local r = row()
  if not win then return {r:add(" Termina IRC", TITLE)} end
  local c = win.conn
  local rows = {r}
  if win.kind == "status" then
    r:add(" " .. (c and c:label() or win.name), TITLE)
    if c then
      local info = row():add(" " .. c:hostport() .. (c.cfg.tls and " TLS" or ""), TITLE_DIM)
      local st = c.state == "ready" and ("as " .. c.nick) or c.state
      info:add("  " .. st, c.state == "ready" and TITLE or TITLE_WARN)
      if tall then rows[2] = info else r:add(" ", TITLE):addA(info:text(), info:attrs()) end
    end
  elseif win.kind == "channel" then
    r:add(" " .. win.name, TITLE)
    if win.joined then r:add(" " .. win.nickCount .. (win.nickCount == 1 and " user" or " users"), TITLE_DIM)
    else r:add(" not joined", TITLE_WARN) end
    if win.topic and win.topic ~= "" then
      if tall then
        local t, a = proto.format(M.clean(win.topic), TITLE_DIM)
        local parts = wrap(t, a, cols - 1)
        for i = 1, math.min(#parts, TOPIC_ROWS) do
          local x = row():add(" ", TITLE):addA(parts[i][1], parts[i][2])
          if i == TOPIC_ROWS and #parts > TOPIC_ROWS then
            x:fit(cols - 1, TITLE):add("\u{2026}", TITLE_DIM)
          end
          rows[#rows + 1] = x
        end
      else
        local t, a = proto.format(M.clean(win.topic), TITLE)
        r:add("  ", TITLE):addA(t, a)
      end
    end
  else
    r:add(" " .. win.name, TITLE):add("  private conversation", TITLE_DIM)
  end
  return rows
end

-- The window bar: my nick, the connection state, then the windows; all of
-- them when they fit in maxRows rows, else the active and busy ones.
local function barRows(cols, maxRows)
  local win = model.active
  local c = win and win.conn
  local head = row()
  if c then
    head:add(" ", BAR):add(c.nick, BAR_MSG)
    if c.state ~= "ready" then head:add(" (" .. c.state .. ")", TITLE_WARN) end
    head:add(" ", BAR)
  end
  if win and win.scroll > 0 then head:add("-- more -- ", TITLE_WARN) end
  local entries = {}
  for i, w in ipairs(model.windows) do
    local label = i .. ":" .. (w.kind == "status" and (w.conn and w.conn:label() or w.name) or w.name)
    entries[#entries + 1] = {w = w, label = cut(label, 20)}
  end
  -- Lay the entries out on rows; nil if they need more than maxRows.
  local function layout(list)
    local rows, tabs = {head:copy()}, {}
    for _, e in ipairs(list) do
      local len = input.len(e.label)
      local r = rows[#rows]
      if r.w + len > cols and r.w > 1 then
        if #rows == maxRows then return nil end
        r = row():add(" ", BAR)
        rows[#rows + 1] = r
      end
      local w = e.w
      local attr = w == win and BAR_ACTIVE
        or w.act == model.HILITE and BAR_HILITE
        or w.act == model.MSG and BAR_MSG
        or w.act == model.EVENT and BAR_EVENT or BAR_DIM
      local x0 = r.w
      r:add(e.label, attr)
      tabs[#tabs + 1] = {#rows, x0, r.w - 1, w}
      r:add(" ", BAR)
    end
    return rows, tabs
  end
  local rows, tabs = layout(entries)
  if not rows then
    local busy = {}
    for _, e in ipairs(entries) do
      if e.w == win or e.w.act > model.NONE then busy[#busy + 1] = e end
    end
    rows, tabs = layout(busy)
    if not rows then
      -- Still too many: the last rows, where the active window is likely.
      local limit = maxRows
      maxRows = 99
      rows, tabs = layout(busy)
      local drop = #rows - limit
      if drop > 0 then
        for _ = 1, drop do table.remove(rows, 1) end
        local kept = {}
        for _, t in ipairs(tabs) do
          if t[1] > drop then kept[#kept + 1] = {t[1] - drop, t[2], t[3], t[4]} end
        end
        tabs = kept
      end
    end
  end
  return rows, tabs
end

-- Width of the nick list column: the longest nick and its prefix, from 8
-- to LISTW cells, so that the messages keep as much room as they can.
local function nickListWidth(win)
  local longest = 6
  for _, n in ipairs(model.sortedNicks(win)) do
    longest = math.max(longest, input.len(n.nick))
  end
  return math.min(LISTW, longest + 2)
end

-- The items of the window list (Alt+W).
function M.pickItems()
  return M.picker and model.windows or {}
end

local function windowItem(r, w, i, selected)
  local base = selected and SELECTED or TEXT
  r:add(string.format("%3d ", i), selected and SELECTED or DIM)
  if w.kind == "status" then
    local c = w.conn
    r:add(c and c:label() or w.name, selected and SELECTED or BRIGHT)
    if c then r:add("  " .. (c.state == "ready" and ("as " .. c.nick) or c.state), selected and SELECTED or DIM) end
  else
    r:add("   " .. w.name, base)
    if w.kind == "channel" then r:add("  " .. w.nickCount, selected and SELECTED or DIM) end
  end
  local mark = w.act == model.HILITE and " !" or w.act == model.MSG and " *" or w.act == model.EVENT and " +" or ""
  r:add(mark, selected and SELECTED or (w.act == model.HILITE and 0x0D or 0x0E))
end

-- The window list, one row per window, the selected one in reverse.
local function pickerRows(cols, h)
  local p = M.picker
  local items = M.pickItems()
  local n = #items
  p.sel = math.max(1, math.min(p.sel, n))
  local sel = p.sel
  local rows = {row():add(" Windows", BRIGHT):add("  Up/Down, Enter, Esc", DIM)}
  local top = math.max(1, math.min(sel - h // 2, n - h + 2))
  for i = top, math.min(n, top + h - 2) do
    local r = row()
    windowItem(r, items[i], i, i == sel)
    if i == sel then r:fit(cols, SELECTED) end
    rows[#rows + 1] = r
    M.pickRows[#rows] = items[i]
  end
  return rows
end

-- The input line: the prompt and the text, over several rows in the tall
-- layout (the rows around the cursor when it is longer). Returns Rows and
-- the cursor's column and row within them.
local function inputRows(win, cols, maxRows)
  local prompt = win and ((win.kind == "status" and "" or win.name) .. "> ") or "> "
  prompt = cut(prompt, cols // 3)
  local pw = input.len(prompt)
  if maxRows == 1 then
    local width = cols - pw - 1
    local start = math.max(0, input.pos - width)
    local r = row():add(prompt, PROMPT):add(input.sub(input.text, start + 1, start + width), TEXT)
    return {r}, pw + input.pos - start, 0
  end
  local all = row():add(prompt, PROMPT):add(input.text, TEXT)
  local t, a = all:text(), all:attrs()
  local cursor = pw + input.pos
  local total = math.max(all.w, cursor) + 1
  local need = (total + cols - 1) // cols
  local first = math.max(0, cursor // cols - (maxRows - 1))
  local rows = {}
  for i = first, math.min(need, first + maxRows) - 1 do
    local s = utf8.offset(t, i * cols + 1) or #t + 1
    local e = utf8.offset(t, (i + 1) * cols + 1) or #t + 1
    rows[#rows + 1] = row():addA(t:sub(s, e - 1), a:sub(s, e - 1))
  end
  if #rows == 0 then rows[1] = row() end
  return rows, cursor % cols, cursor // cols - first
end

function M.draw()
  local cols, nrows = term.cols(), term.rows()
  if cols ~= lastCols or nrows ~= lastRows then
    lastCols, lastRows = cols, nrows
    shown = {}
    term.cls()
  end
  local tall = M.tall()
  local win = model.active
  local y = 1

  -- Title.
  for _, r in ipairs(titleRows(win, cols, tall)) do
    put(y, r, cols, TITLE)
    y = y + 1
  end

  -- Bottom: input line and window bar, measured first.
  local inRows, cx, cy = inputRows(win, cols, tall and INPUT_ROWS or 1)
  local bar, tabs = barRows(cols, tall and BAR_ROWS or 1)
  local bottom = nrows - 1 - #inRows - #bar   -- last message row

  -- The nick list column (wide only: tall has Alt+N).
  M.nickCells = {}
  local list = win and win.kind == "channel" and M.showNicks and cols >= 40
  local listW = list and nickListWidth(win) or 0
  local mw = list and (cols - listW - 1) or cols
  local showTime = mw >= 50
  local top = y
  local h = math.max(1, bottom - top + 1)
  M.msgRows = h

  -- Messages, from the bottom up, or the window list.
  M.pickRows = {}
  if M.picker then
    local pr = pickerRows(cols, h)
    for i = 0, h - 1 do
      put(top + i, pr[i + 1] or row(), cols, TEXT)
    end
    local remap = {}
    for k, w in pairs(M.pickRows) do remap[top + k - 1] = w end
    M.pickRows = remap
  else
    local out = win and messageRows(win, mw, h, tall, showTime) or {}
    local nicks = list and model.sortedNicks(win) or nil
    for yy = top, bottom do
      local idx = (win and win.scroll or 0) + (bottom - yy) + 1
      local r = out[idx] and out[idx]:copy() or row()
      if list then
        r:fit(mw, TEXT)
        r:add(VBAR, SEP)
        local n = nicks[yy - top + 1]
        if yy == bottom and #nicks > h then
          r:add(" +" .. (#nicks - h + 1) .. " more", DIM)
        elseif n then
          local p = n.pre:sub(1, 1)
          r:add(p ~= "" and p or " ", PREFIX_COLORS[p] or ACTION)
          r:add(cut(n.nick, listW - 1), nickColor(n.nick))
          M.nickCells[#M.nickCells + 1] = {yy, mw + 1, cols - 1, n.nick}
        end
      end
      put(yy, r, cols, TEXT)
    end
  end

  -- Window bar and input line.
  y = bottom + 1
  M.tabs = {}
  for i, r in ipairs(bar) do
    put(y, r, cols, BAR)
    y = y + 1
  end
  for _, t in ipairs(tabs) do M.tabs[#M.tabs + 1] = {bottom + t[1], t[2], t[3], t[4]} end
  local iy = y
  for _, r in ipairs(inRows) do
    put(y, r, cols, TEXT)
    y = y + 1
  end
  -- Rows left over when the bottom shrank: nothing to keep there.
  term.cursor(cx, iy + cy)
  term.showcursor(not M.picker)
  model.dirty = false
end

-- Rows of messages on screen (for PgUp / PgDn).
function M.pageRows()
  return M.msgRows
end

-- What is under the pointer: "tab", window / "nick", nick / "pick", window.
function M.hit(x, y)
  for _, t in ipairs(M.tabs) do
    if y == t[1] and x >= t[2] and x <= t[3] then return "tab", t[4] end
  end
  for _, c in ipairs(M.nickCells) do
    if y == c[1] and x >= c[2] and x <= c[3] then return "nick", c[4] end
  end
  if M.pickRows[y] then return "pick", M.pickRows[y] end
end

return M
