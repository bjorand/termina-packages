-- code.tree: the side bar. EXPLORER, the files under the root folder (git
-- state in color), and OUTLINE, the functions of the current Lua file.
local host = require "code.host"
local fs = host.fs
local ui = require "code.ui"

local M = {}

local tree = {
  root = "/", open = {}, rows = {}, sel = 1, top = 1,
  outline = {}, osel = 1, otop = 1,
  part = "files",            -- the part with the keyboard: "files" or "outline"
}
M.state = tree

local function join(dir, name)
  return (dir == "/" and "" or dir) .. "/" .. name
end
M.join = join

local function sorted(dir)
  local list = fs.dir(dir) or {}
  local out = {}
  for _, e in ipairs(list) do
    if e.name ~= ".git" then out[#out + 1] = e end
  end
  table.sort(out, function(a, b)
    if a.dir ~= b.dir then return a.dir end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

-- Lists the rows again (after a change on the filesystem, or a folder
-- opened); the selection stays on the same path.
function M.refresh()
  local was = tree.rows[tree.sel] and tree.rows[tree.sel].path
  local rows = {}
  local function add(dir, depth)
    for _, e in ipairs(sorted(dir)) do
      local p = join(dir, e.name)
      rows[#rows + 1] = {path = p, name = e.name, dir = e.dir, depth = depth}
      if e.dir and tree.open[p] then add(p, depth + 1) end
    end
  end
  add(tree.root, 0)
  tree.rows = rows
  tree.sel = 1
  for i, r in ipairs(rows) do
    if r.path == was then tree.sel = i end
  end
end

function M.setRoot(root)
  tree.root = root
  tree.open = {}
  tree.sel, tree.top = 1, 1
  M.refresh()
end

-- Opens the folders down to path and selects it.
function M.reveal(path)
  local prefix = tree.root == "/" and "" or tree.root
  if path:sub(1, #prefix + 1) ~= prefix .. "/" then return end
  local d = path:match("^(.*)/[^/]*$")
  while d and #d > #prefix do
    tree.open[d] = true
    d = d:match("^(.*)/[^/]*$")
  end
  M.refresh()
  for i, r in ipairs(tree.rows) do
    if r.path == path then tree.sel = i end
  end
end

function M.selected()
  return tree.rows[tree.sel]
end

-- The folder new files go in: the selected one, or the selected file's.
function M.targetDir()
  local r = tree.rows[tree.sel]
  if not r then return tree.root end
  if r.dir then return r.path end
  return r.path:match("^(.*)/[^/]*$") or tree.root
end

function M.setOutline(symbols)
  tree.outline = symbols or {}
  if tree.osel > #tree.outline then tree.osel = math.max(1, #tree.outline) end
end

-- ------------------------------------------------------------------ drawing

-- Where each part is: files and outline rectangles inside r.
local function parts(r)
  local oh = #tree.outline > 0 and math.max(4, math.min(#tree.outline + 1, r.h // 3)) or 0
  local files = {x = r.x, y = r.y + 1, w = r.w, h = r.h - 1 - oh}
  local outline = {x = r.x, y = r.y + r.h - oh + 1, w = r.w, h = oh - 1}
  return files, outline, r.y + r.h - oh
end

local function scrollTo(sel, top, h)
  if sel < top then top = sel end
  if sel >= top + h then top = sel - h + 1 end
  return math.max(1, top)
end

-- gitstate(path) -> "M", "A", "U", "D" or nil
function M.draw(r, focused, gitstate, current)
  local files, outline, oy = parts(r)
  local fattr = focused and tree.part == "files" and ui.HEADER_FOCUS or ui.HEADER
  local title = tree.root == "/" and "/" or tree.root:match("[^/]*$")
  ui.put(r.x, r.y, " EXPLORER: " .. title:upper(), fattr, r.w)
  tree.top = scrollTo(tree.sel, tree.top, files.h)
  for row = 0, files.h - 1 do
    local i = tree.top + row
    local e = tree.rows[i]
    local y = files.y + row
    if not e then
      ui.put(files.x, y, "", ui.TEXT, files.w - 1)
    else
      local st = gitstate(e.path, e.dir)
      local attr = e.dir and ui.DIR or ui.ITEM
      if st == "M" then attr = ui.MODIFIED
      elseif st == "U" or st == "A" then attr = ui.ADDED
      elseif st == "D" then attr = ui.DELETED end
      if i == tree.sel then
        attr = focused and tree.part == "files" and ui.ITEM_SEL or (e.path == current and ui.BRIGHT or ui.ITEM_SEL_DIM)
      elseif e.path == current then
        attr = (attr & 0x0F) | 0x80
      end
      local icon = e.dir and (tree.open[e.path] and ui.OPEN or ui.CLOSED) or " "
      local mark = (not e.dir and st) and (" " .. st) or ""
      local label = string.rep(" ", e.depth) .. icon .. " " .. e.name
      ui.put(files.x, y, ui.fit(label, files.w - 1 - #mark) .. mark, attr, files.w - 1)
    end
  end
  ui.scrollbar(files.x + files.w - 1, files.y, files.h, #tree.rows, tree.top, files.h)
  if outline.h > 0 then
    local oattr = focused and tree.part == "outline" and ui.HEADER_FOCUS or ui.HEADER
    ui.put(r.x, oy, " OUTLINE", oattr, r.w)
    tree.otop = scrollTo(tree.osel, tree.otop, outline.h)
    for row = 0, outline.h - 1 do
      local i = tree.otop + row
      local s = tree.outline[i]
      local y = outline.y + row
      if not s then
        ui.put(outline.x, y, "", ui.TEXT, outline.w)
      else
        local attr = s.kind == "function" and ui.ITEM or ui.DIM
        if i == tree.osel and focused and tree.part == "outline" then attr = ui.ITEM_SEL end
        local icon = s.kind == "function" and ui.FUNC or "\u{2219}"
        local label = string.rep(" ", math.min(4, s.depth // 2)) .. icon .. " " .. s.name
        ui.put(outline.x, y, label, attr, outline.w)
      end
    end
  end
end

-- ------------------------------------------------------------------ input

-- Keys: returns an action table {open = path} / {line = n} / {toggle = path}
-- for the caller, true if handled, false otherwise.
function M.key(e, r)
  if e.type ~= "key" then return false end
  local k = e.key
  local files, outline = parts(r)
  if tree.part == "outline" then
    local n = #tree.outline
    if k == "up" then tree.osel = math.max(1, tree.osel - 1)
    elseif k == "down" then tree.osel = math.min(n, tree.osel + 1)
    elseif k == "pgup" then tree.osel = math.max(1, tree.osel - outline.h)
    elseif k == "pgdn" then tree.osel = math.min(n, tree.osel + outline.h)
    elseif k == "tab" and not e.ctrl then tree.part = "files"
    elseif k == "enter" and tree.outline[tree.osel] then return {line = tree.outline[tree.osel].line}
    else return false end
    return true
  end
  local n = #tree.rows
  local row = tree.rows[tree.sel]
  if k == "up" then tree.sel = math.max(1, tree.sel - 1)
  elseif k == "down" then tree.sel = math.min(n, tree.sel + 1)
  elseif k == "pgup" then tree.sel = math.max(1, tree.sel - files.h)
  elseif k == "pgdn" then tree.sel = math.min(n, tree.sel + files.h)
  elseif k == "home" then tree.sel = 1
  elseif k == "end" then tree.sel = math.max(1, n)
  elseif k == "tab" and not e.ctrl and #tree.outline > 0 then tree.part = "outline"
  elseif k == "right" and row and row.dir then
    if not tree.open[row.path] then
      tree.open[row.path] = true
      M.refresh()
    elseif tree.rows[tree.sel + 1] and tree.rows[tree.sel + 1].depth > row.depth then
      tree.sel = tree.sel + 1
    end
  elseif k == "left" and row then
    if row.dir and tree.open[row.path] then
      tree.open[row.path] = nil
      M.refresh()
    else
      for i = tree.sel - 1, 1, -1 do  -- up to the parent folder
        if tree.rows[i].depth < row.depth then tree.sel = i break end
      end
    end
  elseif k == "enter" and row then
    if row.dir then
      tree.open[row.path] = not tree.open[row.path] or nil
      M.refresh()
    else
      return {open = row.path}
    end
  else
    return false
  end
  return true
end

-- Mouse: same actions as keys.
function M.mouse(e, r)
  local files, outline = parts(r)
  -- scrolls the files to row t, the selection staying in view
  local function setTop(t)
    tree.top = math.max(1, math.min(t, #tree.rows - files.h + 1))
    if tree.sel < tree.top then tree.sel = tree.top end
    if tree.sel >= tree.top + files.h then tree.sel = tree.top + files.h - 1 end
  end
  local barX = files.x + files.w - 1
  if e.type == "wheel" then
    if ui.inside(outline, e.x, e.y) then
      tree.otop = math.max(1, math.min(#tree.outline, tree.otop - e.n * 3))
    else
      setTop(tree.top - e.n * 3)
    end
    return true
  end
  if e.type == "mouse" and e.button == 0 and not e.down then
    tree.dragBar = false
    return true
  end
  if e.type == "move" then
    if tree.dragBar then setTop(ui.scrollTo(e.y, files.y, files.h, #tree.rows, files.h)) end
    return true
  end
  if e.type ~= "mouse" or not e.down or e.button ~= 0 then return e.type == "mouse" end
  if e.x == barX and ui.inside(files, e.x, e.y) and #tree.rows > files.h then
    tree.part, tree.dragBar = "files", true
    setTop(ui.scrollTo(e.y, files.y, files.h, #tree.rows, files.h))
    return true
  end
  if ui.inside(outline, e.x, e.y) then
    local i = tree.otop + e.y - outline.y
    if tree.outline[i] then
      tree.part, tree.osel = "outline", i
      return {line = tree.outline[i].line}
    end
    return true
  end
  if ui.inside(files, e.x, e.y) then
    local i = tree.top + e.y - files.y
    local row = tree.rows[i]
    tree.part = "files"
    if not row then return true end
    tree.sel = i
    if row.dir then
      tree.open[row.path] = not tree.open[row.path] or nil
      M.refresh()
      return true
    end
    return {open = row.path, preview = ui.clickCount(e) == 1}
  end
  return true
end

return M
