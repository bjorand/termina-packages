-- code.panel: the panel under the editor, with four tabs. TERMINAL runs
-- shell commands in a virtual terminal (termina.vt), PROBLEMS lists the
-- syntax errors, SEARCH the results of a search, GIT the changed files.
-- Actions for the editor come back as tables: {jump = {path, line, col}},
-- {diff = row}, {fullscreen = command}...
local vt, fs = termina.vt, termina.fs
local ui = require "code.ui"
local gitui = require "code.gitui"

local M = {}

M.TABS = {"TERMINAL", "PROBLEMS", "SEARCH", "GIT"}

local p = {
  tab = "TERMINAL",
  vt = nil, cwd = "/", input = "", pos = 0, history = {}, hpos = 0,
  job = nil, jobState = nil,   -- the command running in the terminal
  problems = {}, psel = 1, ptop = 1,
  results = {}, rtitle = "", rsel = 1, rtop = 1,
  gsel = 1, gtop = 1,
}
M.state = p

local MAX_HISTORY = 50

function M.setCwd(dir)
  p.cwd = dir
end

-- ------------------------------------------------------------------ terminal

-- The vt fills the panel but its header, its input line and the scroll bar.
local function vtSize(r)
  return math.max(2, r.w - 1), math.max(1, r.h - 2)
end

-- The terminal's scroll bar: total lines, first one shown, lines shown.
local function vtLines(v)
  local _, rows, hist = v:size()
  return rows + hist, hist - v:scroll() + 1, rows
end

-- Scrolls the terminal so that line first (of vtLines) is at the top.
local function vtScrollTo(v, first)
  local _, _, hist = v:size()
  v:scroll(hist - (first - 1) - v:scroll())
end

local function ensureVt(r)
  local w, h = vtSize(r)
  if not p.vt then
    p.vt = vt.open(w, h)
    p.vt:write("\27[90mCommands run here; !command runs it full screen. Ctrl+C stops one.\27[0m\n")
  else
    local cw, ch = p.vt:size()
    if cw ~= w or ch ~= h then p.vt:resize(w, h) end
  end
  return p.vt
end

local function prompt()
  local d = p.cwd == "/" and "/" or p.cwd:match("[^/]*$")
  return d .. "$ "
end

local function resolve(dir)
  if dir:sub(1, 1) ~= "/" then dir = (p.cwd == "/" and "" or p.cwd) .. "/" .. dir end
  local parts = {}
  for part in dir:gmatch("[^/]+") do
    if part == ".." then parts[#parts] = nil
    elseif part ~= "." then parts[#parts + 1] = part end
  end
  return "/" .. table.concat(parts, "/")
end
M.resolve = resolve

-- Runs a command line in the terminal (the panel opens on it), in cwd (the
-- terminal's directory by default).
function M.run(line, r, cwd)
  local v = ensureVt(r)
  p.tab = "TERMINAL"
  v:scroll(false)
  v:write("\27[92m" .. prompt() .. "\27[0m" .. line .. "\n")
  if line:match("^%s*$") then return end
  if #p.history == 0 or p.history[#p.history] ~= line then
    p.history[#p.history + 1] = line
    if #p.history > MAX_HISTORY then table.remove(p.history, 1) end
  end
  p.hpos = #p.history + 1
  local cmd, arg = line:match("^%s*(%S+)%s*(.-)%s*$")
  if cmd == "cd" then
    local d = resolve(arg ~= "" and arg or "/")
    if fs.isdir(d) then p.cwd = d else v:write("cd: no such directory: " .. arg .. "\n") end
    return
  elseif cmd == "clear" then
    v:clear()
    return
  elseif line:match("^%s*!") then
    return {fullscreen = line:match("^%s*!%s*(.*)$")}
  end
  local pid, err = v:spawn(line, cwd or p.cwd)
  if not pid then
    v:write("\27[91m" .. err .. "\27[0m\n")
    return
  end
  p.job, p.jobState = line, "running"
end

function M.busy()
  return p.job ~= nil
end

-- Called often: follows the job. Returns true if the panel changed.
function M.tick()
  local v = p.vt
  if not v then return false end
  local changed = v:changed()
  if p.job then
    local st, code = v:job()
    if st == "done" then
      if code ~= 0 then v:write("\27[90m[exit " .. code .. "]\27[0m\n") end
      p.job, p.jobState = nil, nil
      changed = true
      M.onJobDone = true
    elseif st == "stopped" then
      v:kill("KILL")
      v:write("\27[93mIt reads the keyboard: run it full screen with !" .. p.job .. "\27[0m\n")
    end
  end
  return changed
end

local function termKey(e, r)
  local v = ensureVt(r)
  if e.type == "char" then
    if p.job then return true end
    local s = p.input
    local b = ui.offset(s, p.pos)
    p.input = s:sub(1, b - 1) .. e.ch .. s:sub(b)
    p.pos = p.pos + 1
    return true
  end
  local k = e.key
  if e.ctrl and k == "c" then
    if p.job then v:kill("INT")
    else
      v:write("\27[92m" .. prompt() .. "\27[0m" .. p.input .. "^C\n")
      p.input, p.pos = "", 0
    end
    return true
  end
  if k == "pgup" then v:scroll(math.max(1, select(2, v:size()) - 1)) return true end
  if k == "pgdn" then v:scroll(-math.max(1, select(2, v:size()) - 1)) return true end
  if e.ctrl and k == "l" then v:clear() return true end
  if p.job then return k ~= "esc" and not e.ctrl and not k:match("^f%d") end
  local s, n = p.input, ui.len(p.input)
  if k == "enter" then
    p.input, p.pos = "", 0
    return M.run(s, r) or true
  elseif k == "backspace" and p.pos > 0 then
    p.input = ui.sub(s, 1, p.pos - 1) .. ui.sub(s, p.pos + 1)
    p.pos = p.pos - 1
  elseif k == "delete" and p.pos < n then
    p.input = ui.sub(s, 1, p.pos) .. ui.sub(s, p.pos + 2)
  elseif k == "left" then p.pos = math.max(0, p.pos - 1)
  elseif k == "right" then p.pos = math.min(n, p.pos + 1)
  elseif k == "home" then p.pos = 0
  elseif k == "end" then p.pos = n
  elseif k == "up" and p.hpos > 1 then
    p.hpos = p.hpos - 1
    p.input = p.history[p.hpos]
    p.pos = ui.len(p.input)
  elseif k == "down" and p.hpos <= #p.history then
    p.hpos = p.hpos + 1
    p.input = p.history[p.hpos] or ""
    p.pos = ui.len(p.input)
  elseif k == "esc" then
    p.input, p.pos = "", 0
  else
    return k ~= "tab" and not e.ctrl and not k:match("^f%d")
  end
  return true
end

-- A "file.lua:12:" in a line of output: the place it points to.
local function placeIn(line)
  local file, l = line:match("([%w_%./%-]+%.%w+):(%d+):")
  if not file then return nil end
  -- Lua names a script by its path without the first "/": "games/x.lua"
  local path = resolve(file)
  if not fs.exists(path) and fs.exists("/" .. file) then path = "/" .. file end
  return {path = path, line = tonumber(l)}
end

-- ------------------------------------------------------------------ lists

local function listScroll(sel, top, h)
  if sel < top then top = sel end
  if sel >= top + h then top = sel - h + 1 end
  return math.max(1, top)
end

local function listKey(e, n, sel, h)
  local k = e.key
  if k == "up" then return math.max(1, sel - 1) end
  if k == "down" then return math.min(math.max(1, n), sel + 1) end
  if k == "pgup" then return math.max(1, sel - h) end
  if k == "pgdn" then return math.min(math.max(1, n), sel + h) end
  if k == "home" then return 1 end
  if k == "end" then return math.max(1, n) end
  return nil
end

function M.setProblems(list)
  p.problems = list
  if p.psel > #list then p.psel = math.max(1, #list) end
end

function M.setResults(title, list)
  p.results, p.rtitle, p.rsel, p.rtop = list, title, 1, 1
  p.tab = "SEARCH"
end

local function shortPath(path, root)
  if root ~= "/" and path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
  return path
end

-- ------------------------------------------------------------------ drawing

-- The title of a tab, with its count.
local function label(t)
  if t == "PROBLEMS" and #p.problems > 0 then return t .. " " .. #p.problems end
  if t == "GIT" and gitui.available() then
    local s, c = gitui.counts()
    if s + c > 0 then return t .. " " .. (s + c) end
  end
  return t
end

-- The tab under column x of the header, if any.
local function tabAt(r, x)
  local cx = r.x + 1
  for _, t in ipairs(M.TABS) do
    local w = #label(t) + 2
    if x >= cx and x < cx + w then return t end
    cx = cx + w + 1
  end
  return nil
end
M.tabAt = tabAt

-- resizing: the header is being dragged (it is drawn brighter).
function M.draw(r, focused, root, resizing)
  -- header: a line between the tabs, the handle to resize the panel
  ui.hline(r.x, r.y, r.w, resizing and ui.BRIGHT or ui.FRAME)
  local cx = r.x + 1
  for _, t in ipairs(M.TABS) do
    local name = label(t)
    local attr = t == p.tab and (focused and ui.TAB_ACTIVE or ui.BRIGHT) or ui.HEADER
    ui.put(cx, r.y, " " .. name .. " ", attr)
    cx = cx + #name + 3
  end
  if p.tab == "TERMINAL" and p.job then
    ui.put(r.x + r.w - 22, r.y, " running: Ctrl+C stops", ui.WARN, 22)
  end
  local body = {x = r.x, y = r.y + 1, w = r.w, h = r.h - 1}
  if p.tab == "TERMINAL" then
    local v = ensureVt(r)
    -- v:scroll() marks the vt as changed: read the position before drawing it
    local total, first, shown = vtLines(v)
    v:draw(body.x, body.y, body.w - 1, body.h - 1)
    ui.scrollbar(body.x + body.w - 1, body.y, body.h - 1, total, first, shown)
    local iy = r.y + r.h - 1
    if p.job then
      ui.put(r.x, iy, "  " .. p.job, ui.DIM, r.w)
      if focused then termina.term.showcursor(false) end
    else
      local pr = prompt()
      local width = r.w - #pr
      local start = math.max(0, p.pos - width + 1)
      ui.put(r.x, iy, pr, 0x0A)
      ui.put(r.x + #pr, iy, ui.sub(p.input, start + 1, start + width), ui.TEXT, width)
      if focused then
        termina.term.cursor(r.x + #pr + p.pos - start, iy)
        termina.term.showcursor(true)
      end
    end
    return
  end
  if focused then termina.term.showcursor(false) end
  local rows, sel, top
  if p.tab == "PROBLEMS" then
    p.ptop = listScroll(p.psel, p.ptop, body.h)
    rows, sel, top = p.problems, p.psel, p.ptop
    if #rows == 0 then
      ui.put(body.x, body.y, "  No problems in the open files.", ui.DIM, body.w)
      body = {x = body.x, y = body.y + 1, w = body.w, h = body.h - 1}
    end
  elseif p.tab == "SEARCH" then
    p.rtop = listScroll(p.rsel, p.rtop, body.h - 1)
    ui.put(body.x, body.y, "  " .. p.rtitle, ui.DIM, body.w)
    body = {x = body.x, y = body.y + 1, w = body.w, h = body.h - 1}
    rows, sel, top = p.results, p.rsel, p.rtop
  else
    if not gitui.available() then
      ui.put(body.x, body.y, "  Not a git repository.", ui.DIM, body.w)
      body = {x = body.x, y = body.y + 1, w = body.w, h = body.h - 1}
      rows, sel, top = {}, 1, 1
    else
      local st = gitui.state
      local s, c = gitui.counts()
      local head = "  On branch " .. (st.branch or "(detached)") ..
          (s + c == 0 and ": nothing to commit" or "") ..
          "     s stage/unstage  a all  d discard  Enter diff  c commit  p push  l pull  r refresh"
      ui.put(body.x, body.y, head, ui.DIM, body.w)
      body = {x = body.x, y = body.y + 1, w = body.w, h = body.h - 1}
      rows = gitui.rows()
      if p.gsel > #rows then p.gsel = math.max(1, #rows) end
      -- the selection is on a file, not on a section title
      if rows[p.gsel] and rows[p.gsel].title and rows[p.gsel + 1] then p.gsel = p.gsel + 1 end
      p.gtop = listScroll(p.gsel, p.gtop, body.h)
      sel, top = p.gsel, p.gtop
    end
  end
  for row = 0, body.h - 1 do
    local i = top + row
    local e = rows[i]
    local y = body.y + row
    if not e then
      ui.put(body.x, y, "", ui.TEXT, body.w)
    else
      local text, attr
      if p.tab == "PROBLEMS" then
        text = string.format("  %s:%d: %s", shortPath(e.path, root), e.line, e.msg)
        attr = ui.ERROR
      elseif p.tab == "SEARCH" then
        text = string.format("  %s:%d: %s", shortPath(e.path, root), e.line, (e.text:gsub("^%s+", "")))
        attr = ui.ITEM
      elseif e.title then
        text, attr = " " .. e.title, ui.HEADER_FOCUS
      else
        local kind = e.kind == "" and "untracked" or e.kind
        text = string.format("    %-10s %s", kind, e.path)
        attr = e.staged and ui.ADDED or (e.kind == "deleted" and ui.DELETED or ui.MODIFIED)
      end
      if i == sel then attr = focused and ui.ITEM_SEL or ui.BRIGHT end
      ui.put(body.x, y, text, attr, body.w)
    end
  end
end

-- ------------------------------------------------------------------ input

local function gitKey(e)
  local rows = gitui.rows()
  local row = rows[p.gsel]
  local k = e.type == "char" and e.ch or e.key
  local n = listKey(e, #rows, p.gsel, 5)
  if e.type == "key" and n then
    -- section titles are skipped, in the direction of the move
    local dir = n < p.gsel and -1 or 1
    while rows[n] and rows[n].title and rows[n + dir] do n = n + dir end
    if rows[n] and rows[n].title then n = p.gsel end
    p.gsel = n
    return true
  end
  if k == "r" then gitui.refresh() return true end
  if k == "c" then return {commit = true} end
  if k == "p" then return {push = true} end
  if k == "l" then return {pull = true} end
  if k == "a" then
    local ok, err = gitui.stageAll()
    return ok or {message = err}
  end
  if not row or row.title then return k ~= "esc" and e.type == "char" end
  if k == "s" or k == " " then
    local ok, err
    if row.staged then ok, err = gitui.unstage(row.path) else ok, err = gitui.stage(row.path) end
    return ok or {message = err}
  end
  if k == "d" and not row.staged and row.kind ~= "" then return {discard = row.path} end
  if k == "enter" then return {diff = row} end
  return e.type == "char"
end

-- Keys when the panel has the focus.
function M.key(e, r)
  if p.tab == "TERMINAL" then return termKey(e, r) end
  if p.tab == "GIT" then return gitKey(e) end
  if e.type ~= "key" then return false end
  local h = r.h - 2
  if p.tab == "PROBLEMS" then
    local n = listKey(e, #p.problems, p.psel, h)
    if n then p.psel = n return true end
    local e2 = p.problems[p.psel]
    if e.key == "enter" and e2 then return {jump = {path = e2.path, line = e2.line}} end
  else
    local n = listKey(e, #p.results, p.rsel, h)
    if n then p.rsel = n return true end
    local e2 = p.results[p.rsel]
    if e.key == "enter" and e2 then return {jump = {path = e2.path, line = e2.line, col = e2.col}} end
  end
  return false
end

function M.mouse(e, r)
  -- the terminal's scroll bar, clicked or dragged
  local barX, barY, barH = r.x + r.w - 1, r.y + 1, r.h - 2
  if e.type == "mouse" and e.button == 0 and not e.down then
    p.dragBar = false
    return true
  end
  if e.type == "move" then
    if p.dragBar and p.vt then
      local total, _, shown = vtLines(p.vt)
      vtScrollTo(p.vt, ui.scrollTo(e.y, barY, barH, total, shown))
    end
    return true
  end
  if e.type == "mouse" and e.down and e.button == 0 and p.tab == "TERMINAL" and p.vt and
      e.x == barX and e.y >= barY and e.y < barY + barH then
    p.dragBar = true
    local total, _, shown = vtLines(p.vt)
    vtScrollTo(p.vt, ui.scrollTo(e.y, barY, barH, total, shown))
    return true
  end
  if e.type == "mouse" and e.down and e.button == 0 and e.y == r.y then
    local t = tabAt(r, e.x)
    if t then p.tab = t end
    return true
  end
  if e.type == "wheel" then
    if p.tab == "TERMINAL" and p.vt then p.vt:scroll(e.n * 3)
    elseif p.tab == "PROBLEMS" then p.ptop = math.max(1, p.ptop - e.n * 3)
    elseif p.tab == "SEARCH" then p.rtop = math.max(1, p.rtop - e.n * 3)
    else p.gtop = math.max(1, p.gtop - e.n * 3) end
    return true
  end
  if e.type ~= "mouse" or not e.down or e.button ~= 0 then return e.type == "mouse" end
  local row = e.y - (r.y + 1)
  local double = ui.clickCount(e) >= 2
  if p.tab == "TERMINAL" then
    if p.vt and row < r.h - 2 then
      local place = placeIn(p.vt:line(row) or "")
      if place then return {jump = place} end
    end
    return true
  elseif p.tab == "PROBLEMS" then
    local i = p.ptop + row
    if p.problems[i] then
      p.psel = i
      return {jump = {path = p.problems[i].path, line = p.problems[i].line}}
    end
  elseif p.tab == "SEARCH" then
    local i = p.rtop + row - 1
    if p.results[i] then
      p.rsel = i
      local e2 = p.results[i]
      return {jump = {path = e2.path, line = e2.line, col = e2.col}}
    end
  elseif gitui.available() then
    local i = p.gtop + row - 1
    local rows = gitui.rows()
    if rows[i] then
      p.gsel = i
      if double and not rows[i].title then return {diff = rows[i]} end
    end
  end
  return true
end

function M.close()
  if p.vt then p.vt:close() end
  p.vt = nil
end

return M
