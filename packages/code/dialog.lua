-- code.dialog: modal boxes over the editor. pick() is a list filtered by
-- what is typed (quick open, command palette), ask() a line of input,
-- confirm() a yes/no question, menu() a context menu at the pointer.
-- Each one runs until it is answered; the caller redraws everything after.
local host = require "code.host"
local term = host.term
local ui = require "code.ui"

local M = {}


-- How well query matches label: nil if its characters are not all there in
-- order; higher for consecutive characters and the start of words.
local function score(label, query)
  if query == "" then return 0 end
  local l, q = label:lower(), query:lower()
  local s, pos, last = 0, 1, -1
  for i = 1, #q do
    local c = q:sub(i, i)
    local at = l:find(c, pos, true)
    if not at then return nil end
    s = s + (at == last + 1 and 5 or 1)
    if at == 1 or l:sub(at - 1, at - 1):match("[/%._%- ]") then s = s + 3 end
    last, pos = at, at + 1
  end
  return s - #l / 100
end

-- Edits a one-line input: returns the new text and cursor, or nil if the
-- key is not an editing key.
local function editLine(e, text, pos)
  if e.type == "paste" then  -- the first line of text pasted from the terminal
    local t = e.text:gsub("[\r\n].*", "")
    local b = ui.offset(text, pos)
    return text:sub(1, b - 1) .. t .. text:sub(b), pos + ui.len(t)
  end
  if e.type == "char" then
    local b = ui.offset(text, pos)
    return text:sub(1, b - 1) .. e.ch .. text:sub(b), pos + 1
  end
  local k, n = e.key, ui.len(text)
  if k == "backspace" and pos > 0 then return ui.sub(text, 1, pos - 1) .. ui.sub(text, pos + 1), pos - 1 end
  if k == "delete" and pos < n then return ui.sub(text, 1, pos) .. ui.sub(text, pos + 2), pos end
  if k == "left" then return text, math.max(0, pos - 1) end
  if k == "right" then return text, math.min(n, pos + 1) end
  if k == "home" then return text, 0 end
  if k == "end" then return text, n end
  if e.ctrl and k == "v" then
    local t = host.sys.clipboard():gsub("[\r\n].*", "")
    local b = ui.offset(text, pos)
    return text:sub(1, b - 1) .. t .. text:sub(b), pos + ui.len(t)
  end
  if e.ctrl and k == "u" then return "", 0 end
  return nil
end

local function drawInput(x, y, w, label, text, pos)
  local width = w - ui.len(label)
  local start = math.max(0, pos - width + 1)
  ui.put(x, y, label, ui.POPUP)
  ui.put(x + ui.len(label), y, ui.sub(text, start + 1, start + width), 0x07, width)
  term.cursor(x + ui.len(label) + pos - start, y)
  term.showcursor(true)
end

-- items: list of {label, detail}; returns the item chosen, or nil (Esc).
-- opts: {title, text (initial query), width}
function M.pick(items, opts)
  local COLS, ROWS = term.cols(), term.rows()
  opts = opts or {}
  local w = math.min(COLS - 4, opts.width or 70)
  local h = math.min(ROWS - 6, 18)
  local x, y = (COLS - w) // 2, 2
  local text, pos = opts.text or "", ui.len(opts.text or "")
  local sel, top = 1, 1
  local shown = {}
  local function filter()
    shown = {}
    for _, it in ipairs(items) do
      local s = score(it.label, text)
      if s then shown[#shown + 1] = {item = it, s = s} end
    end
    if text ~= "" then table.sort(shown, function(a, b) return a.s > b.s end) end
    sel, top = 1, 1
  end
  filter()
  local listH = h - 3
  while true do
    ui.box(x, y, w, h, ui.POPUP, opts.title)
    drawInput(x + 1, y + 1, w - 2, " > ", text, pos)
    if sel < top then top = sel end
    if sel >= top + listH then top = sel - listH + 1 end
    for row = 0, listH - 1 do
      local e = shown[top + row]
      local yy = y + 2 + row
      if not e then
        ui.put(x + 1, yy, "", ui.POPUP, w - 2)
      else
        local attr = top + row == sel and ui.POPUP_SEL or ui.POPUP
        local detail = e.item.detail or ""
        local room = w - 4 - ui.len(detail)
        ui.put(x + 1, yy, " " .. ui.fit(e.item.label, room) .. " " .. detail .. " ", attr, w - 2)
      end
    end
    if #shown == 0 then ui.put(x + 1, y + 2, "  (nothing matches)", ui.POPUP_DIM, w - 2) end
    local e = ui.waitEvent()
    if e.type == "key" and (e.key == "esc" or (e.ctrl and e.key == "q")) then return nil end
    if e.type == "key" and e.key == "enter" then return shown[sel] and shown[sel].item end
    if e.type == "key" and e.key == "up" then sel = math.max(1, sel - 1)
    elseif e.type == "key" and e.key == "down" then sel = math.min(math.max(1, #shown), sel + 1)
    elseif e.type == "key" and e.key == "pgup" then sel = math.max(1, sel - listH)
    elseif e.type == "key" and e.key == "pgdn" then sel = math.min(math.max(1, #shown), sel + listH)
    elseif e.type == "wheel" then sel = math.max(1, math.min(#shown, sel - e.n))
    elseif e.type == "mouse" and e.down and e.button == 0 then
      local i = top + e.y - (y + 2)
      if e.x >= x and e.x < x + w and e.y >= y + 2 and e.y < y + 2 + listH and shown[i] then
        return shown[i].item
      elseif not ui.inside({x = x, y = y, w = w, h = h}, e.x, e.y) then
        return nil
      end
    elseif e.type == "key" or e.type == "char" or e.type == "paste" then
      local t, p = editLine(e, text, pos)
      if t then
        local changed = t ~= text
        text, pos = t, p
        if changed then filter() end
      end
    end
  end
end

-- A line of input in a box; returns the text, or nil (Esc).
function M.ask(question, default)
  local COLS, ROWS = term.cols(), term.rows()
  local w = math.min(COLS - 4, math.max(50, ui.len(question) + 30))
  local x, y = (COLS - w) // 2, 2
  local text, pos = default or "", ui.len(default or "")
  while true do
    ui.box(x, y, w, 3, ui.POPUP)
    drawInput(x + 1, y + 1, w - 2, " " .. question .. " ", text, pos)
    local e = ui.waitEvent()
    if e.type == "key" and e.key == "esc" then return nil end
    if e.type == "key" and e.key == "enter" then return text end
    if e.type == "mouse" and e.down and not ui.inside({x = x, y = y, w = w, h = 3}, e.x, e.y) then
      return nil
    end
    if e.type == "key" or e.type == "char" or e.type == "paste" then
      local t, p = editLine(e, text, pos)
      if t then text, pos = t, p end
    end
  end
end

-- A question answered by one of the keys of choices ("yn", "ync");
-- returns that letter, or nil (Esc).
function M.confirm(question, choices)
  local COLS, ROWS = term.cols(), term.rows()
  choices = choices or "yn"
  local hint = "(" .. choices:upper():gsub(".", "%0/"):sub(1, -2) .. ")"
  local text = " " .. question .. " " .. hint .. " "
  local w = math.min(COLS - 4, ui.len(text) + 2)
  local x, y = (COLS - w) // 2, 2
  ui.box(x, y, w, 3, ui.POPUP)
  ui.put(x + 1, y + 1, text, ui.POPUP, w - 2)
  term.showcursor(false)
  while true do
    local e = ui.waitEvent()
    if e.type == "key" and e.key == "esc" then return nil end
    local c = e.type == "char" and e.ch:lower() or (e.type == "key" and #e.key == 1 and not e.ctrl and e.key)
    if c and choices:find(c, 1, true) then return c end
  end
end

-- A context menu at (x, y): items {label, key}; returns the item, or nil.
function M.menu(x, y, items)
  local COLS, ROWS = term.cols(), term.rows()
  local w = 0
  for _, it in ipairs(items) do w = math.max(w, ui.len(it.label) + ui.len(it.key or "") + 4) end
  w = w + 2
  local h = #items + 2
  x = math.max(0, math.min(x, COLS - w))
  y = math.max(0, math.min(y, ROWS - h))
  local sel = 1
  term.showcursor(false)
  while true do
    ui.box(x, y, w, h, ui.POPUP)
    for i, it in ipairs(items) do
      local attr = i == sel and ui.POPUP_SEL or ui.POPUP
      local hint = it.key or ""
      ui.put(x + 1, y + i, " " .. ui.fit(it.label, w - 4 - ui.len(hint)) .. hint .. " ", attr, w - 2)
    end
    local e = ui.waitEvent()
    if e.type == "key" then
      if e.key == "esc" then return nil end
      if e.key == "enter" then return items[sel] end
      if e.key == "up" then sel = (sel - 2) % #items + 1 end
      if e.key == "down" then sel = sel % #items + 1 end
    elseif e.type == "move" or (e.type == "mouse" and e.down) then
      local i = e.y - y
      local inside = e.x > x and e.x < x + w - 1 and i >= 1 and i <= #items
      if inside then sel = i end
      if e.type == "mouse" and e.button == 0 then
        if inside then return items[i] end
        return nil
      end
    end
  end
end

M.score = score
return M
