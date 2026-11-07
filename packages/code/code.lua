-- code: a code editor in the spirit of VS Code, for the text screen.
--   code              the current folder
--   code dir          a folder
--   code file.lua     a file (its folder, or its git repository, as root)
-- Explorer on the left, tabs, the editor, a panel below (terminal, problems,
-- search, git) and a status bar. The mouse selects, drags, scrolls and
-- clicks everywhere. F1 or Ctrl+Shift+P lists every command.
if not (termina and termina.vt) then
  print("code needs TERMINA 4.2.0 or later")
  return
end
local term, key, sys, fs = termina.term, termina.key, termina.sys, termina.fs
local system = require "system"
local ui = require "code.ui"
local buffer = require "code.buffer"
local view = require "code.view"
local tree = require "code.tree"
local panel = require "code.panel"
local lsp = require "code.lsp"
local gitui = require "code.gitui"
local dialog = require "code.dialog"

sys.memlimit(2 * 1024 * 1024)

local COLS, ROWS = term.cols(), term.rows()
local CHECK_MS = 500      -- after typing stops: syntax check, outline
local MARKS_MS = 1200     -- git gutter
local MSG_MS = 5000

local bufs, cur = {}, 0          -- open buffers in tab order, the current one
local focus = "editor"           -- "editor", "tree" or "panel"
local showTree, showPanel = true, true
local treeW = math.max(18, COLS // 5)
local panelH = math.max(6, ROWS // 4)
local root = fs.cwd()
local R = {}                     -- rectangles of the panes (layout())
local tabs = {}                  -- where each tab is drawn, for clicks
local msg, msgAttr, msgAt = nil, ui.STATUS, 0
local find = ""                  -- the text searched (F3)
local jumps = {}                 -- where to go back to (Alt+Left)
local comp                       -- completion popup: {items, sel, top, word}
local lastEdit = 0
local running = true
local dragSplit = false          -- resizing the explorer with the mouse
local dragPanel = false          -- resizing the panel (its header) with the mouse
local fileList                   -- the files under root, for quick open

-- ------------------------------------------------------------------ helpers

local function message(text, attr)
  msg, msgAttr, msgAt = text, attr or ui.STATUS, sys.millis()
end

local function errorMsg(text)
  message(text, ui.STATUS_ERR)
end

local function current()
  return bufs[cur]
end

local function absPath(p)
  if p:sub(1, 1) ~= "/" then p = (root == "/" and "" or root) .. "/" .. p end
  local parts = {}
  for part in p:gmatch("[^/]+") do
    if part == ".." then parts[#parts] = nil
    elseif part ~= "." then parts[#parts + 1] = part end
  end
  return "/" .. table.concat(parts, "/")
end

local function relPath(p)
  if root ~= "/" and p:sub(1, #root + 1) == root .. "/" then return p:sub(#root + 2) end
  if root == "/" then return p:sub(2) end
  return p
end

local function byPath()
  local t = {}
  for _, b in ipairs(bufs) do
    if b.path then t[b.path] = b end
  end
  return t
end

local function layout()
  local tw = showTree and treeW or 0
  local ex = showTree and tw + 1 or 0
  local ew = COLS - ex
  local contentH = ROWS - 3
  local ph = showPanel and math.min(panelH, contentH - 4) or 0
  R.tree = {x = 0, y = 1, w = tw, h = ROWS - 2}
  R.tabs = {x = ex, y = 1, w = ew, h = 1}
  R.editor = {x = ex, y = 2, w = ew, h = contentH - ph}
  R.panel = {x = ex, y = 2 + contentH - ph, w = ew, h = ph}
  R.status = {x = 0, y = ROWS - 1, w = COLS, h = 1}
end

local function problems()
  local list = {}
  for _, b in ipairs(bufs) do
    for l, d in pairs(b.diags) do
      list[#list + 1] = {path = b.path or b:title(), line = l, msg = d.msg}
    end
  end
  table.sort(list, function(a, b) return a.path < b.path or (a.path == b.path and a.line < b.line) end)
  panel.setProblems(list)
end

-- Syntax check, outline and git marks of b, now.
local function analyze(b)
  b.diags = lsp.check(b)
  b.checked = b.changes
  b.marks = gitui.marks(b)
  b.marked = b.changes
  problems()
  if b == current() then tree.setOutline(b.lang == "lua" and lsp.symbols(b.lines) or {}) end
end

-- ------------------------------------------------------------------ buffers

local function remember()
  local b = current()
  if b and b.path then
    jumps[#jumps + 1] = {path = b.path, line = b.cy, col = b.cx}
    if #jumps > 50 then table.remove(jumps, 1) end
  end
end

local function selectTab(i)
  if i < 1 or i > #bufs then return end
  cur = i
  local b = bufs[i]
  if b.path then tree.reveal(b.path) end
  tree.setOutline(b.lang == "lua" and lsp.symbols(b.lines) or {})
end

-- Opens path (or switches to it) and puts the cursor on line, col.
local function open(path, line, col)
  for i, b in ipairs(bufs) do
    if b.path == path then
      selectTab(i)
      if line then
        b:moveTo(line, col or 0)
        view.center(b, R.editor, line)
      end
      return b
    end
  end
  if fs.isdir(path) then return nil end
  local b, err = buffer.new(path)
  if not b then
    errorMsg(path .. ": " .. err)
    return nil
  end
  table.insert(bufs, cur + 1, b)
  selectTab(cur + 1)
  if b.tabs then message("Tabs were turned into spaces; saving keeps the spaces.") end
  if line then
    b:moveTo(line, col or 0)
    view.center(b, R.editor, line)
  end
  analyze(b)
  return b
end

local function jumpTo(path, line, col)
  remember()
  local b = open(path, line, col)
  if b then focus = "editor" end
  return b
end

local function goBack()
  local j = table.remove(jumps)
  if j then open(j.path, j.line, j.col) end
end

local function save(b)
  b = b or current()
  if not b or b.readonly then return false end
  local path = b.path
  if not path then
    local name = dialog.ask("Save as:", relPath(tree.targetDir()) .. "/")
    if not name or name:match("/$") then return false end
    path = absPath(name)
  end
  local ok, err = b:save(path)
  if not ok then
    errorMsg(err)
    return false
  end
  message("Saved " .. relPath(path))
  gitui.refresh()
  tree.refresh()
  fileList = nil
  lsp.forget()
  analyze(b)
  return true
end

-- Closes buffer i; asks first if it has unsaved changes. False if not closed.
local function close(i)
  local b = bufs[i]
  if not b then return true end
  if b:modified() then
    local a = dialog.confirm("Save changes to " .. b:title() .. "?", "ync")
    if a == "y" then
      if not save(b) then return false end
    elseif a ~= "n" then
      return false
    end
  end
  table.remove(bufs, i)
  if cur >= i then cur = cur - 1 end
  if cur < 1 and #bufs > 0 then cur = 1 end
  if bufs[cur] then selectTab(cur) else tree.setOutline({}) end
  problems()
  return true
end

local function newFile(dir)
  local name = dialog.ask("New file:", relPath(dir or tree.targetDir()) .. "/")
  if not name or name:match("/$") or name == "" then return end
  local path = absPath(name)
  if fs.exists(path) then return open(path) end
  local d = path:match("^(.*)/[^/]*$")
  if d ~= "" and not fs.isdir(d) then fs.mkdir(d) end
  if not fs.write(path, "") then return errorMsg("Cannot create " .. name) end
  tree.refresh()
  fileList = nil
  gitui.refresh()
  open(path)
  focus = "editor"
end

local function newFolder()
  local name = dialog.ask("New folder:", relPath(tree.targetDir()) .. "/")
  if not name or name == "" then return end
  if not fs.mkdir(absPath(name)) then return errorMsg("Cannot create " .. name) end
  tree.refresh()
end

local function rename(path)
  path = path or (tree.selected() and tree.selected().path)
  if not path then return end
  local name = dialog.ask("Rename to:", relPath(path))
  if not name or name == "" or absPath(name) == path then return end
  local to = absPath(name)
  if not fs.rename(path, to) then return errorMsg("Cannot rename to " .. name) end
  for _, b in ipairs(bufs) do
    if b.path == path then b.path = to
    elseif b.path and b.path:sub(1, #path + 1) == path .. "/" then b.path = to .. b.path:sub(#path + 1) end
  end
  tree.refresh()
  fileList = nil
  gitui.refresh()
end

local function delete(path)
  path = path or (tree.selected() and tree.selected().path)
  if not path then return end
  local isDir = fs.isdir(path)
  if dialog.confirm("Delete " .. relPath(path) .. (isDir and " and all it holds" or "") .. "?") ~= "y" then return end
  local ok = isDir and fs.rmtree(path) or fs.remove(path)
  if not ok then return errorMsg("Cannot delete " .. relPath(path)) end
  for i = #bufs, 1, -1 do
    local p = bufs[i].path
    if p == path or (p and p:sub(1, #path + 1) == path .. "/") then
      bufs[i].changes = bufs[i].saved  -- gone: no question
      close(i)
    end
  end
  tree.refresh()
  fileList = nil
  gitui.refresh()
end

-- Buffers whose file changed on disk (git pull, restore) and that hold no
-- unsaved change are read again.
local function reloadClean()
  for i, b in ipairs(bufs) do
    if b.path and not b:modified() and fs.exists(b.path) then
      local nb = buffer.new(b.path)
      if nb and nb:text() ~= b:text() then
        nb.cy, nb.cx, nb.top = math.min(b.cy, #nb.lines), 0, b.top
        bufs[i] = nb
        analyze(nb)
      end
    end
  end
end

-- ------------------------------------------------------------------ files

local function listFiles()
  if fileList then return fileList end
  local out = {}
  local function walk(dir)
    for _, e in ipairs(fs.dir(dir) or {}) do
      if #out >= 2000 then return end
      local p = (dir == "/" and "" or dir) .. "/" .. e.name
      if e.dir then
        if e.name ~= ".git" and e.name ~= ".pkg" then walk(p) end
      else
        out[#out + 1] = p
      end
    end
  end
  walk(root)
  table.sort(out)
  fileList = out
  return out
end

-- Lines holding text (any case) in the files under root.
local function searchFiles(text)
  local low = text:lower()
  local out = {}
  local open_ = byPath()
  for _, path in ipairs(listFiles()) do
    if #out >= 300 then break end
    local lines
    if open_[path] then lines = open_[path].lines
    elseif (fs.size(path) or 0) <= 128 * 1024 then
      local t = fs.read(path) or ""
      if not t:find("\0", 1, true) then
        lines = {}
        for l in (t .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = l end
      end
    end
    for i, s in ipairs(lines or {}) do
      local a = s:lower():find(low, 1, true)
      if a then
        out[#out + 1] = {path = path, line = i, col = ui.len(s:sub(1, a - 1)), text = s}
        if #out >= 300 then break end
      end
    end
    sys.yield()
  end
  return out
end

-- ------------------------------------------------------------------ running

local origTermios = system.tcgetattr(io.stdin)

-- Ctrl+C and Ctrl+Z are keys for the editor, not signals.
local function rawMode(on)
  if not origTermios then return end
  if on and origTermios.lflag:has_all_of(system.L_ISIG) then
    system.tcsetattr(io.stdin, system.TCSANOW, {lflag = origTermios.lflag - system.L_ISIG})
  else
    system.tcsetattr(io.stdin, system.TCSANOW, origTermios)
  end
end

local function redrawAll()
  term.cls()
end

-- Runs a command on the whole screen, then comes back.
local function fullscreen(cmd)
  rawMode(false)
  term.attr(0x07)
  term.cls()
  term.showcursor(true)
  os.execute(cmd)
  term.attr(0x07)
  termina.write("\n\27[90m[" .. cmd .. ": done, press a key]\27[0m")
  while not key.poll() do sys.sleep(20) end
  rawMode(true)
  redrawAll()
  gitui.refresh()
  tree.refresh()
  reloadClean()
end

local function quote(s)
  return gitui.quote(s)
end

local function runFile(full)
  local b = current()
  if not b or not b.path then return message("Save the file first.") end
  if b:modified() and not save(b) then return end
  local cmd
  if b.lang == "lua" then cmd = "lua " .. quote(b.path)
  elseif b.lang == "sh" then cmd = "sh " .. quote(b.path)
  else return message("F5 runs .lua and .sh files.") end
  if full then return fullscreen(cmd) end
  showPanel = true
  layout()
  if panel.busy() then return message("A command is still running in the terminal.") end
  panel.run(cmd, R.panel, b.path:match("^(.*)/[^/]*$") or "/")
end

local function gitCommand(cmd)
  if not gitui.available() then return message("Not a git repository.") end
  showPanel = true
  layout()
  if panel.busy() then return message("A command is still running in the terminal.") end
  panel.run(cmd, R.panel, gitui.state.repo.root)
end

local function commit()
  if not gitui.available() then return message("Not a git repository.") end
  local s = gitui.counts()
  if s == 0 then
    if dialog.confirm("Nothing is staged. Stage every change and commit?") ~= "y" then return end
    local ok, err = gitui.stageAll()
    if not ok then return errorMsg(err) end
  end
  local text = dialog.ask("Commit message:")
  if not text or text == "" then return end
  gitCommand("git commit -m " .. quote(text))
end

-- ------------------------------------------------------------------ navigation

local function findNext(dir)
  local b = current()
  if not b or find == "" then return end
  local l, c = b.cy, b.cx
  if dir < 0 then
    local l1, c1 = b:selection()
    if l1 then l, c = l1, c1 end
  end
  local fl, c1, c2 = b:find(find, l, c, dir)
  if not fl then return errorMsg("Not found: " .. find) end
  b.ay, b.ax, b.cy, b.cx = fl, c1, fl, c2
  view.center(b, R.editor, fl)
end

local function findPrompt()
  local b = current()
  if not b then return end
  local default = b:selectedText()
  if not default or default:find("\n") then default = find end
  local t = dialog.ask("Find:", default)
  if not t or t == "" then return end
  find = t
  local l1, c1 = b:selection()
  if l1 then b.cy, b.cx = l1, c1 end
  findNext(1)
end

local function replacePrompt()
  local b = current()
  if not b or b.readonly then return end
  local default = b:selectedText()
  if not default or default:find("\n") then default = find end
  local t = dialog.ask("Replace:", default)
  if not t or t == "" then return end
  local w = dialog.ask("Replace \"" .. t .. "\" with:", "")
  if not w then return end
  local n = b:replaceAll(t, w)
  message(n .. " replaced.")
end

local function gotoLine()
  local b = current()
  if not b then return end
  local t = dialog.ask("Go to line:", "")
  local n = tonumber(t or "")
  if not n then return end
  remember()
  b:moveTo(math.floor(n), 0)
  view.center(b, R.editor, b.cy)
end

-- The name at the cursor, with what comes before a "." or ":" (M.draw).
local function nameAtCursor(b)
  local a, z = b:wordAt(b.cy, b.cx)
  if not a then return nil end
  local s = b.lines[b.cy]
  local before = s:sub(1, ui.offset(s, a) - 1)
  local chain = before:match("([%w_.:]*)$") or ""
  return chain .. ui.sub(s, a + 1, z), ui.sub(s, a + 1, z)
end

local function definition()
  local b = current()
  if not b then return end
  local name = nameAtCursor(b)
  if not name then return message("No name at the cursor.") end
  local found = lsp.definitions(name, root, byPath())
  if #found == 0 then return message("No definition found for " .. name .. ".") end
  local d = found[1]
  if #found > 1 then
    local items = {}
    for _, f in ipairs(found) do items[#items + 1] = {label = f.name, detail = relPath(f.path) .. ":" .. f.line, f = f} end
    local it = dialog.pick(items, {title = "Definitions of " .. lsp.short(name)})
    if not it then return end
    d = it.f
  end
  jumpTo(d.path, d.line, 0)
end

local function references()
  local b = current()
  if not b then return end
  local _, word = nameAtCursor(b)
  if not word then return message("No name at the cursor.") end
  local list = lsp.references(word, root, byPath())
  panel.setResults(#list .. " reference(s) to " .. word, list)
  showPanel = true
end

local function findInFiles()
  local b = current()
  local default = b and b:selectedText()
  if not default or default:find("\n") then default = find end
  local t = dialog.ask("Find in files:", default)
  if not t or t == "" then return end
  message("Searching...")
  local list = searchFiles(t)
  panel.setResults(#list .. " result(s) for \"" .. t .. "\"" .. (#list >= 300 and " (first 300)" or ""), list)
  showPanel = true
  focus = "panel"
end

local function quickOpen()
  local items = {}
  for _, p in ipairs(listFiles()) do items[#items + 1] = {label = relPath(p), path = p} end
  local it = dialog.pick(items, {title = "Open file (" .. #items .. ")"})
  if it then jumpTo(it.path) end
end

local function gotoSymbol()
  local b = current()
  if not b or b.lang ~= "lua" then return end
  local items = {}
  for _, s in ipairs(lsp.symbols(b.lines)) do
    items[#items + 1] = {label = s.name, detail = tostring(s.line), line = s.line}
  end
  local it = dialog.pick(items, {title = "Go to symbol"})
  if it then
    remember()
    b:moveTo(it.line, 0)
    view.center(b, R.editor, it.line)
  end
end

local function openPrompt()
  local t = dialog.ask("Open:", relPath(tree.targetDir()) .. "/")
  if t and t ~= "" then jumpTo(absPath(t)) end
end

-- ------------------------------------------------------------------ completion

local function completion()
  local b = current()
  if not b or b.readonly then return end
  local items, word = lsp.complete(b)
  if #items == 0 then
    comp = nil
    return
  end
  comp = {items = items, sel = 1, top = 1, word = word}
end

local function accept()
  local b = current()
  local it = comp.items[comp.sel]
  comp = nil
  if not it then return end
  b:begin(nil)
  b:deleteSelection()
  local _, word = lsp.prefix(b.lines[b.cy], b.cx)
  local n = ui.len(word)
  b:delete(b.cy, b.cx - n, b.cy, b.cx)
  b.cx = b.cx - n
  b.cy, b.cx = b:insert(b.cy, b.cx, it.label)
  b.lastKind, b.want = nil, b.cx
end

local function compKey(e)
  if e.type ~= "key" then return false end
  local k = e.key
  if k == "esc" then comp = nil return true end
  if k == "up" then comp.sel = (comp.sel - 2) % #comp.items + 1 return true end
  if k == "down" then comp.sel = comp.sel % #comp.items + 1 return true end
  if k == "pgup" then comp.sel = math.max(1, comp.sel - 8) return true end
  if k == "pgdn" then comp.sel = math.min(#comp.items, comp.sel + 8) return true end
  if k == "enter" or k == "tab" then accept() return true end
  return false
end

local function drawCompletion()
  local b = current()
  if not comp or not b then return end
  local r = R.editor
  local h = math.min(8, #comp.items)
  local w = 12
  for _, it in ipairs(comp.items) do w = math.max(w, ui.len(it.label) + #it.kind + 3) end
  w = math.min(w, 40)
  local x = r.x + view.gutterWidth(b) + (b.cx - b.left) - ui.len(comp.word)
  local y = r.y + (b.cy - b.top) + 1
  if y + h > r.y + r.h then y = y - h - 1 end
  x = math.max(r.x, math.min(x, COLS - w))
  if comp.sel < comp.top then comp.top = comp.sel end
  if comp.sel >= comp.top + h then comp.top = comp.sel - h + 1 end
  for i = 0, h - 1 do
    local it = comp.items[comp.top + i]
    local attr = comp.top + i == comp.sel and ui.POPUP_SEL or ui.POPUP
    local label = ui.fit(it.label, w - #it.kind - 3)
    ui.put(x, y + i, " " .. label .. " " .. it.kind .. " ", attr, w)
    term.cell(x + w - #it.kind - 1, y + i, " ", attr)
    ui.put(x + w - #it.kind - 1, y + i, it.kind, comp.top + i == comp.sel and ui.POPUP_SEL or ui.POPUP_DIM)
  end
end

-- ------------------------------------------------------------------ commands

local commands  -- defined below, used by the palette

local function palette()
  local items = {}
  for _, c in ipairs(commands) do items[#items + 1] = {label = c.name, detail = c.key, c = c} end
  local it = dialog.pick(items, {title = "Commands"})
  if it then it.c.fn() end
end

local function toggleTree()
  showTree = not showTree
  if not showTree and focus == "tree" then focus = "editor" end
end

local function togglePanel()
  showPanel = not showPanel
  if not showPanel and focus == "panel" then focus = "editor" end
  if showPanel then focus = "panel" end
end

local function showTab(name)
  panel.state.tab = name
  showPanel = true
  focus = "panel"
end

local function quit()
  for i = #bufs, 1, -1 do
    if bufs[i]:modified() then
      cur = i
      if not close(i) then return end
    end
  end
  running = false
end

local function help()
  local lines = {
    "TERMINA CODE: keys",
    "",
    "Ctrl+P open a file        Ctrl+Shift+P / F1 all commands",
    "Ctrl+S save   Ctrl+W close the tab   Ctrl+N new file   Ctrl+Q quit",
    "Ctrl+Tab / Ctrl+PgDn next tab   Ctrl+PgUp previous tab",
    "Ctrl+B explorer   Ctrl+J panel   F6 next pane   Esc back to the editor",
    "",
    "Ctrl+C / Ctrl+X / Ctrl+V copy, cut, paste (no selection: the line)",
    "Ctrl+Z / Ctrl+Y undo, redo   Ctrl+A select all   Shift+arrows select",
    "Ctrl+F find   F3 / Shift+F3 next, previous   Ctrl+H replace",
    "Ctrl+G go to line   Ctrl+Shift+O go to symbol   Ctrl+Shift+F find in files",
    "Tab / Shift+Tab indent   Ctrl+/ comment   Alt+Up/Down move the line",
    "Ctrl+D duplicate the line   Ctrl+Shift+K delete it",
    "",
    "Ctrl+Space complete   F12 go to definition   Shift+F12 references",
    "Alt+Left go back   F5 run the file in the terminal   Ctrl+F5 full screen",
    "Ctrl+Shift+G git   Ctrl+Shift+M problems",
    "",
    "Mouse: click, drag to select, double click a word, triple click a line,",
    "wheel to scroll, middle click to paste, right click for a menu.",
    "In the terminal: !command runs it full screen.",
  }
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, ui.len(l)) end
  w = math.min(COLS - 2, w + 4)
  local h = #lines + 2
  local x, y = (COLS - w) // 2, math.max(1, (ROWS - h) // 2)
  ui.box(x, y, w, h, ui.POPUP)
  for i, l in ipairs(lines) do ui.put(x + 1, y + i, " " .. l, i == 1 and 0x7F or ui.POPUP, w - 2) end
  term.showcursor(false)
  ui.waitEvent()
end

commands = {
  {name = "Open file...", key = "Ctrl+P", fn = quickOpen},
  {name = "Open path...", key = "Ctrl+O", fn = openPrompt},
  {name = "New file...", key = "Ctrl+N", fn = function() newFile() end},
  {name = "New folder...", key = "Ctrl+Shift+N", fn = newFolder},
  {name = "Save", key = "Ctrl+S", fn = function() save() end},
  {name = "Save all", key = "", fn = function() for _, b in ipairs(bufs) do if b:modified() then save(b) end end end},
  {name = "Close tab", key = "Ctrl+W", fn = function() close(cur) end},
  {name = "Rename file...", key = "F2", fn = function() rename(focus == "tree" and nil or (current() and current().path)) end},
  {name = "Delete file...", key = "", fn = function() delete() end},
  {name = "Find...", key = "Ctrl+F", fn = findPrompt},
  {name = "Replace...", key = "Ctrl+H", fn = replacePrompt},
  {name = "Find in files...", key = "Ctrl+Shift+F", fn = findInFiles},
  {name = "Go to line...", key = "Ctrl+G", fn = gotoLine},
  {name = "Go to symbol...", key = "Ctrl+Shift+O", fn = gotoSymbol},
  {name = "Go to definition", key = "F12", fn = definition},
  {name = "Find references", key = "Shift+F12", fn = references},
  {name = "Go back", key = "Alt+Left", fn = goBack},
  {name = "Run the file", key = "F5", fn = function() runFile(false) end},
  {name = "Run the file full screen", key = "Ctrl+F5", fn = function() runFile(true) end},
  {name = "Toggle explorer", key = "Ctrl+B", fn = toggleTree},
  {name = "Toggle panel", key = "Ctrl+J", fn = togglePanel},
  {name = "Terminal", key = "", fn = function() showTab("TERMINAL") end},
  {name = "Problems", key = "Ctrl+Shift+M", fn = function() showTab("PROBLEMS") end},
  {name = "Git: changes", key = "Ctrl+Shift+G", fn = function() gitui.refresh() showTab("GIT") end},
  {name = "Git: commit...", key = "", fn = commit},
  {name = "Git: push", key = "", fn = function() gitCommand("git push") end},
  {name = "Git: pull", key = "", fn = function() gitCommand("git pull") end},
  {name = "Git: stage all", key = "", fn = function() local ok, err = gitui.stageAll() if not ok then errorMsg(err) end end},
  {name = "Git: log", key = "", fn = function() gitCommand("git log -n 10") end},
  {name = "Keys", key = "F1", fn = help},
  {name = "Quit", key = "Ctrl+Q", fn = quit},
}

-- ------------------------------------------------------------------ drawing

local function drawTabs()
  local r = R.tabs
  tabs = {}
  -- first tab shown: the current one must fit
  local widths = {}
  for i, b in ipairs(bufs) do widths[i] = ui.len(b:title()) + 5 end
  local first, used = cur, 0
  for i = cur, 1, -1 do
    if used + widths[i] > r.w then break end
    used = used + widths[i]
    first = i
  end
  local x = r.x
  for i = math.max(1, first), #bufs do
    local b = bufs[i]
    local w = widths[i]
    if x + w > r.x + r.w then break end
    local attr = i == cur and ui.TAB_ACTIVE or ui.TAB
    local mark = b:modified() and ui.DOT or " "
    ui.put(x, r.y, " " .. b:title() .. " ", attr)
    local mx = x + ui.len(b:title()) + 2
    ui.put(mx, r.y, mark, i == cur and 0x7E or ui.TAB_MODIFIED)
    ui.put(mx + 1, r.y, "x ", i == cur and 0x78 or ui.DIM)
    tabs[#tabs + 1] = {i = i, x1 = x, x2 = x + w - 1, close = mx + 1}
    x = x + w
  end
  if x < r.x + r.w then ui.put(x, r.y, "", ui.TEXT, r.x + r.w - x) end
  if #bufs == 0 then ui.put(r.x, r.y, "", ui.TEXT, r.w) end
end

local function drawWelcome(r)
  ui.fill(r.x, r.y, r.w, r.h, ui.TEXT)
  local lines = {
    {"T E R M I N A   C O D E", 0x0F},
    {"", 0x07},
    {"Ctrl+P   open a file", 0x07},
    {"Ctrl+N   new file", 0x07},
    {"F1       all commands", 0x07},
    {"Ctrl+Q   quit", 0x07},
    {"", 0x07},
    {root, 0x08},
  }
  local y = r.y + math.max(0, (r.h - #lines) // 2)
  for i, l in ipairs(lines) do
    local w = ui.len(l[1])
    ui.put(r.x + math.max(0, (r.w - w) // 2), y + i - 1, l[1], l[2])
  end
  if focus == "editor" then term.showcursor(false) end
end

local function drawStatus()
  local r = R.status
  local b = current()
  local left = ""
  if gitui.available() and gitui.state.branch then
    local s, c = gitui.counts()
    left = " \u{00B1} " .. gitui.state.branch .. (s > 0 and (" +" .. s) or "") .. (c > 0 and (" ~" .. c) or "")
  end
  local np = #panel.state.problems
  if np > 0 then left = left .. "  \u{2666} " .. np .. " error" .. (np > 1 and "s" or "") end
  local right = ""
  if b then
    local lang = b.lang == "lua" and "Lua" or b.lang == "sh" and "Shell" or b.lang == "diff" and "Diff" or "Text"
    local l1, c1, l2, c2 = b:selection()
    local sel = ""
    if l1 then sel = string.format(" (%d selected)", #b:get(l1, c1, l2, c2)) end
    right = string.format("Ln %d, Col %d%s  %s%s ", b.cy, b.cx + 1, sel, lang, b.crlf and "  CRLF" or "")
  end
  local attr = ui.STATUS
  if msg and sys.millis() - msgAt < MSG_MS then
    left = left .. "   " .. msg
    attr = msgAttr
  else
    msg = nil
  end
  local w = COLS - ui.len(right)
  ui.put(0, r.y, ui.fit(left, w), attr, w)
  ui.put(w, r.y, right, ui.STATUS)
end

local function draw()
  layout()
  term.showcursor(false)
  local b = current()
  -- explorer and its border
  if showTree then
    local cp = b and b.path
    tree.draw(R.tree, focus == "tree", gitui.fileState, cp)
    ui.vline(R.tree.w, 1, ROWS - 2, dragSplit and ui.BRIGHT or ui.FRAME)
  end
  drawTabs()
  if b then
    view.scroll(b, R.editor)
    view.draw(b, R.editor, focus == "editor" and not comp, find)
  else
    drawWelcome(R.editor)
  end
  if showPanel then
    panel.draw(R.panel, focus == "panel", root, dragPanel)
    -- where the two borders meet
    if showTree then term.cell(R.tree.w, R.panel.y, ui.TEE_RIGHT, (dragSplit or dragPanel) and ui.BRIGHT or ui.FRAME) end
  end
  drawStatus()
  drawCompletion()
  if focus == "editor" and b and comp then
    -- the cursor stays in the text while completing
    local r = R.editor
    term.cursor(r.x + view.gutterWidth(b) + b.cx - b.left, r.y + b.cy - b.top)
    term.showcursor(true)
  end
end

-- ------------------------------------------------------------------ input

local function contextMenu(e)
  local b = current()
  local items
  if ui.inside(R.tree, e.x, e.y) and showTree then
    items = {
      {label = "New file...", key = "^N", fn = function() newFile() end},
      {label = "New folder...", fn = newFolder},
      {label = "Rename...", key = "F2", fn = function() rename() end},
      {label = "Delete...", key = "Del", fn = function() delete() end},
      {label = "Copy path", fn = function()
        local s = tree.selected()
        if s then sys.setclipboard(s.path) end
      end},
    }
  elseif b and ui.inside(R.editor, e.x, e.y) then
    items = {
      {label = "Cut", key = "^X", fn = function() view.cut(b) end},
      {label = "Copy", key = "^C", fn = function() view.copy(b) end},
      {label = "Paste", key = "^V", fn = function() if not b.readonly then view.paste(b) end end},
      {label = "Select all", key = "^A", fn = function() b:selectAll() end},
    }
    if b.lang == "lua" then
      items[#items + 1] = {label = "Go to definition", key = "F12", fn = definition}
      items[#items + 1] = {label = "Find references", key = "S-F12", fn = references}
    end
    items[#items + 1] = {label = "Command palette", key = "F1", fn = palette}
  else
    return
  end
  local it = dialog.menu(e.x, e.y, items)
  if it then it.fn() end
end

local dragTarget  -- the pane a mouse button went down in
local action      -- handles what the panel asks for (defined below)

local function onMouse(e)
  local b = current()
  if e.type == "mouse" and not e.down and e.button == 0 then
    dragSplit, dragPanel = false, false
    if dragTarget == "editor" and b then view.mouse(b, e, R.editor)
    elseif dragTarget == "tree" then tree.mouse(e, R.tree)
    elseif dragTarget == "panel" then panel.mouse(e, R.panel) end
    dragTarget = nil
    return
  end
  if e.type == "move" then
    if dragSplit then
      treeW = math.max(10, math.min(COLS - 30, e.x))
    elseif dragPanel then
      -- the header follows the pointer: the panel goes down to the status bar
      panelH = math.max(3, math.min(ROWS - 7, ROWS - 1 - e.y))
    elseif dragTarget == "editor" and b then
      view.mouse(b, e, R.editor)
    elseif dragTarget == "tree" then
      tree.mouse(e, R.tree)
    elseif dragTarget == "panel" then
      panel.mouse(e, R.panel)
    end
    return
  end
  if e.type == "mouse" and e.down and e.button == 1 then
    if ui.inside(R.tree, e.x, e.y) and showTree then
      focus = "tree"
      tree.mouse({type = "mouse", down = true, button = 0, x = e.x, y = e.y}, R.tree)
    elseif b and ui.inside(R.editor, e.x, e.y) then
      focus = "editor"
      local l1 = b:selection()
      if not l1 then
        local l, c = view.posAt(b, R.editor, e.x, e.y)
        b:moveTo(l, c)
      end
    end
    draw()
    return contextMenu(e)
  end
  local pressed = e.type == "mouse" and e.down
  if showTree and e.x == R.tree.w and pressed and e.button == 0 and e.y >= 1 and e.y < ROWS - 1 then
    dragSplit = true
    return
  end
  if showPanel and pressed and e.button == 0 and e.y == R.panel.y and ui.inside(R.panel, e.x, e.y) and
      not panel.tabAt(R.panel, e.x) then
    dragPanel = true
    return
  end
  if showTree and ui.inside(R.tree, e.x, e.y) then
    if pressed then
      focus, comp = "tree", nil
      if e.button == 0 then dragTarget = "tree" end
    end
    local act = tree.mouse(e, R.tree)
    if type(act) == "table" then
      if act.open then
        jumpTo(act.open)
        if act.preview then focus = "tree" end
      elseif act.line and b then
        remember()
        b:moveTo(act.line, 0)
        view.center(b, R.editor, act.line)
        focus = "editor"
      end
    end
    return
  end
  if ui.inside(R.tabs, e.x, e.y) then
    if pressed then
      for _, t in ipairs(tabs) do
        if e.x >= t.x1 and e.x <= t.x2 then
          if (e.x == t.close and e.button == 0) or e.button == 2 then close(t.i)
          else selectTab(t.i) focus = "editor" end
        end
      end
    elseif e.type == "wheel" and #bufs > 0 then
      selectTab((cur - 1 - e.n) % #bufs + 1)
    end
    return
  end
  if showPanel and ui.inside(R.panel, e.x, e.y) then
    if pressed then
      focus, comp = "panel", nil
      if e.button == 0 then dragTarget = "panel" end
    end
    local act = panel.mouse(e, R.panel)
    if type(act) == "table" then return action(act) end
    return
  end
  if ui.inside(R.status, e.x, e.y) then
    if pressed and e.button == 0 then
      if e.x < 20 and gitui.available() then showTab("GIT")
      elseif #panel.state.problems > 0 and e.x < 40 then showTab("PROBLEMS") end
    end
    return
  end
  if b and ui.inside(R.editor, e.x, e.y) then
    if pressed then
      focus = "editor"
      comp = nil
      if e.button == 0 then dragTarget = "editor" end
    end
    view.mouse(b, e, R.editor)
    return
  end
end

-- Actions coming back from the panel.
function action(act)
  if act.jump then
    local j = act.jump
    if fs.exists(j.path) then jumpTo(j.path, j.line, j.col)
    else
      for i, b in ipairs(bufs) do
        if b:title() == j.path or b.path == j.path then
          selectTab(i)
          b:moveTo(j.line, j.col or 0)
          view.center(b, R.editor, j.line)
          focus = "editor"
        end
      end
    end
  elseif act.fullscreen then
    fullscreen(act.fullscreen)
  elseif act.diff then
    local text = gitui.diffText(act.diff.path, act.diff.staged)
    local b = buffer.scratch("diff " .. act.diff.path:match("[^/]*$"), text, "diff")
    table.insert(bufs, cur + 1, b)
    selectTab(cur + 1)
    focus = "editor"
  elseif act.commit then
    commit()
  elseif act.push then
    gitCommand("git push")
  elseif act.pull then
    for _, b in ipairs(bufs) do
      if b:modified() then return message("Save your changes before pulling.") end
    end
    gitCommand("git pull")
  elseif act.discard then
    if dialog.confirm("Discard the changes of " .. act.discard .. "?") == "y" then
      local ok, err = gitui.discard(act.discard)
      if not ok then errorMsg(err) end
      reloadClean()
      tree.refresh()
    end
  elseif act.message then
    errorMsg(act.message)
  end
end

local function onKey(e)
  local b = current()
  local k = e.type == "key" and e.key or nil
  local ctrl, shift, alt = e.ctrl, e.shift, e.alt
  -- completion popup first
  if comp and focus == "editor" then
    if compKey(e) then return end
  end
  if k then
    if ctrl and not alt then
      if k == "q" and not shift then return quit() end
      if k == "s" and not shift then return save() end
      if k == "p" then if shift then return palette() else return quickOpen() end end
      if k == "o" and shift then return gotoSymbol() end
      if k == "o" then return openPrompt() end
      if k == "n" then if shift then return newFolder() else return newFile() end end
      if k == "w" and not shift then return close(cur) end
      if k == "b" and not shift then return toggleTree() end
      if k == "j" and not shift then return togglePanel() end
      if k == "f" and shift then return findInFiles() end
      if k == "f" then return findPrompt() end
      if k == "h" and not shift then return replacePrompt() end
      if k == "g" and shift then gitui.refresh() return showTab("GIT") end
      if k == "g" then return gotoLine() end
      if k == "m" and shift then return showTab("PROBLEMS") end
      if k == "e" and shift then showTree = true focus = "tree" return end
      if k == "tab" or k == "pgdn" then if #bufs > 0 then selectTab(cur % #bufs + 1) end return end
      if k == "pgup" then if #bufs > 0 then selectTab((cur - 2) % #bufs + 1) end return end
      if k == " " then return completion() end
      if k == "f5" then return runFile(true) end
    end
    if alt and k == "left" then return goBack() end
    if k == "f1" then return palette() end
    if k == "f5" then return runFile(false) end
    if k == "f6" then
      local order = {"editor"}
      if showPanel then order[#order + 1] = "panel" end
      if showTree then table.insert(order, 1, "tree") end
      for i, f in ipairs(order) do
        if f == focus then focus = order[i % #order + 1] break end
      end
      return
    end
    if k == "f12" and shift then return references() end
    if k == "f12" then return definition() end
    if k == "f3" then return findNext(shift and -1 or 1) end
    if k == "f2" then return rename(focus == "tree" and nil or (b and b.path)) end
  end
  if focus == "tree" then
    if k == "esc" then focus = "editor" return end
    if k == "delete" then return delete() end
    local act = tree.key(e, R.tree)
    if type(act) == "table" then
      if act.open then jumpTo(act.open)
      elseif act.line and b then
        remember()
        b:moveTo(act.line, 0)
        view.center(b, R.editor, act.line)
        focus = "editor"
      end
    end
    return
  end
  if focus == "panel" then
    local act = panel.key(e, R.panel)
    if type(act) == "table" then return action(act) end
    if not act and k == "esc" then focus = "editor" end
    return
  end
  -- editor
  if not b then return end
  if k == "esc" then
    find, comp = "", nil
    b.ay = nil
    return
  end
  if view.editKey(b, e) then lastEdit = sys.millis() return end
  local before = b.changes
  if view.key(b, e, R.editor) then
    if b.changes ~= before then
      lastEdit = sys.millis()
      if comp then completion()
      elseif e.type == "char" and (e.ch == "." or e.ch == ":") and b.lang == "lua" then completion() end
    elseif comp then
      comp = nil
    end
  end
end

-- ------------------------------------------------------------------ idle work

local function idle()
  local changed = panel.tick()
  if panel.onJobDone then
    panel.onJobDone = nil
    gitui.refresh()
    tree.refresh()
    fileList = nil
    reloadClean()
    changed = true
  end
  local b = current()
  local now = sys.millis()
  if b and now - lastEdit > CHECK_MS and b.checked ~= b.changes then
    b.diags = lsp.check(b)
    b.checked = b.changes
    problems()
    tree.setOutline(b.lang == "lua" and lsp.symbols(b.lines) or {})
    changed = true
  end
  if b and now - lastEdit > MARKS_MS and b.marked ~= b.changes then
    b.marks = gitui.marks(b)
    b.marked = b.changes
    changed = true
  end
  if msg and now - msgAt >= MSG_MS then changed = true end
  return changed
end

-- ------------------------------------------------------------------ main

local function start()
  local a = arg[1]
  if a then
    local p = a:sub(1, 1) == "/" and a or absPath(a)
    p = absPath(p)
    if fs.isdir(p) then
      root = p
    else
      root = p:match("^(.*)/[^/]*$")
      if root == "" then root = "/" end
      if gitui.open(root) then root = gitui.state.repo.root end
      open(p)
    end
  end
  if not gitui.available() then gitui.open(root) end
  gitui.refresh()
  tree.setRoot(root)
  panel.setCwd(root)
  if current() then
    tree.reveal(current().path)
    analyze(current())
  end
end

local function main()
  rawMode(true)
  term.attr(0x07)
  term.cls()
  layout()
  start()
  draw()
  while running do
    local e = key.poll()
    local any = false
    while e do
      any = true
      if e.type == "key" or e.type == "char" then onKey(e) else onMouse(e) end
      if not running then break end
      e = key.poll()
    end
    if not running then break end
    if idle() or any then draw() end
    sys.sleep(any and 5 or 20)
  end
end

-- Unsaved work goes to file~ if the editor fails.
local function rescue()
  for _, b in ipairs(bufs) do
    if b.path and b:modified() then pcall(fs.write, b.path .. "~", b:text()) end
  end
end

local ok, err = xpcall(main, debug.traceback)
panel.close()
rawMode(false)
term.attr(0x07)
term.cls()
term.showcursor(true)
if not ok then
  rescue()
  print("code stopped: " .. tostring(err))
  print("Unsaved files were written next to them, with a ~ at the end of their name.")
end
