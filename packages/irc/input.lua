-- irc.input: the line typed at the bottom of the screen, with history and
-- Tab completion of nicks, channels and commands. Text is UTF-8; one
-- character takes one cell.
local sys = termina.sys

local M = {text = "", pos = 0, hist = {}, histAt = nil, maxHist = 50}

-- ------------------------------------------------------------- UTF-8

function M.len(s)
  return utf8.len(s) or #s
end

-- Byte offset of character i (1-based); past the end: #s + 1.
function M.offset(s, i)
  return utf8.offset(s, i) or #s + 1
end

-- Characters i to j (1-based, inclusive).
function M.sub(s, i, j)
  local n = M.len(s)
  j = j or n
  if i < 1 then i = 1 end
  if j > n then j = n end
  if i > j then return "" end
  return s:sub(M.offset(s, i), M.offset(s, j + 1) - 1)
end

-- ------------------------------------------------------------- editing

local function insert(t)
  local s, pos = M.text, M.pos
  local b = M.offset(s, pos + 1)
  M.text = s:sub(1, b - 1) .. t .. s:sub(b)
  M.pos = pos + M.len(t)
end

function M.set(text)
  M.text, M.pos = text, M.len(text)
end

local function wordStart(s, pos)
  local before = M.sub(s, 1, pos)
  local a = before:match("()%S*%s*$")
  return M.len(before:sub(1, a - 1))
end

-- Completion: complete(word, first) -> list of candidates for the word
-- before the cursor (first: it starts the line). Set by the main program.
M.complete = nil
local comp -- {list, i, start, suffix}: the Tab cycle in progress

local function tab()
  local s, pos = M.text, M.pos
  if not comp then
    local start = wordStart(s, pos)
    local word = M.sub(s, start + 1, pos)
    if word == "" or not M.complete then return end
    local list = M.complete(word, start == 0)
    if #list == 0 then return end
    comp = {list = list, i = 0, start = start, len = M.len(word)}
  end
  comp.i = comp.i % #comp.list + 1
  local pick = comp.list[comp.i]
  if comp.start == 0 and not pick:match("^[/#&]") then pick = pick .. ":" end
  pick = pick .. " "
  local head = M.sub(s, 1, comp.start)
  local tail = M.sub(s, comp.start + comp.len + 1)
  M.text = head .. pick .. tail
  M.pos = comp.start + M.len(pick)
  comp.len = M.len(pick)
end

-- key(e) -> "submit", text when Enter is pressed; true when the event
-- changed the line; nil when it is not an editing key.
function M.key(e)
  if e.type == "char" then
    comp = nil
    insert(e.ch)
    return true
  end
  if e.type ~= "key" then return nil end
  local k, n = e.key, M.len(M.text)
  if k ~= "tab" then comp = nil end
  if k == "enter" then
    local t = M.text
    if t ~= "" and t ~= M.hist[#M.hist] then
      M.hist[#M.hist + 1] = t
      if #M.hist > M.maxHist then table.remove(M.hist, 1) end
    end
    M.text, M.pos, M.histAt = "", 0, nil
    return "submit", t
  elseif k == "tab" then tab()
  elseif e.alt then return nil
  elseif k == "backspace" then
    if e.ctrl then
      local a = wordStart(M.text, M.pos)
      M.text = M.sub(M.text, 1, a) .. M.sub(M.text, M.pos + 1)
      M.pos = a
    elseif M.pos > 0 then
      M.text = M.sub(M.text, 1, M.pos - 1) .. M.sub(M.text, M.pos + 1)
      M.pos = M.pos - 1
    end
  elseif k == "delete" then
    if M.pos < n then M.text = M.sub(M.text, 1, M.pos) .. M.sub(M.text, M.pos + 2) end
  elseif k == "left" then
    M.pos = e.ctrl and wordStart(M.text, M.pos) or math.max(0, M.pos - 1)
  elseif k == "right" then
    if e.ctrl then
      local after = M.sub(M.text, M.pos + 1)
      local b = after:match("^%s*%S*()")
      M.pos = M.pos + M.len(after:sub(1, b - 1))
    else
      M.pos = math.min(n, M.pos + 1)
    end
  elseif k == "home" and not e.ctrl then M.pos = 0
  elseif k == "end" and not e.ctrl then M.pos = n
  elseif k == "up" then
    if #M.hist == 0 then return true end
    if not M.histAt then
      M.draft = M.text
      M.histAt = #M.hist
    elseif M.histAt > 1 then
      M.histAt = M.histAt - 1
    end
    M.set(M.hist[M.histAt])
  elseif k == "down" then
    if not M.histAt then return true end
    if M.histAt < #M.hist then
      M.histAt = M.histAt + 1
      M.set(M.hist[M.histAt])
    else
      M.histAt = nil
      M.set(M.draft or "")
    end
  elseif e.ctrl and k == "u" then M.text, M.pos = M.sub(M.text, M.pos + 1), 0
  elseif e.ctrl and k == "k" then M.text = M.sub(M.text, 1, M.pos)
  elseif e.ctrl and k == "w" then
    local a = wordStart(M.text, M.pos)
    M.text = M.sub(M.text, 1, a) .. M.sub(M.text, M.pos + 1)
    M.pos = a
  elseif e.ctrl and k == "a" then M.pos = 0
  elseif e.ctrl and k == "e" then M.pos = n
  elseif e.ctrl and k == "v" then
    -- Pasted lines are joined: one message, not a flood.
    local t = (sys.clipboard() or ""):gsub("\r?\n", " "):gsub("[%c]", "")
    insert(t)
  else
    return nil
  end
  return true
end

return M
