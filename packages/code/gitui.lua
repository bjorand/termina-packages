-- code.gitui: the git state of the root folder: branch, changed files,
-- gutter marks. On Termina through the firmware's git client (git.cmd),
-- elsewhere through the git command (code.gitcli). Commit, push and pull
-- run the git command in the terminal panel instead, so that the editor
-- stays responsive during network transfers.
local host = require "code.host"
local diff = require "code.diff"

local M = {}

local ok, git = pcall(require, "git.cmd")
if not ok then git = require "code.gitcli" end

local state = {
  repo = nil, branch = nil, files = {}, dirs = {},
  staged = {}, unstaged = {}, untracked = {}, err = nil,
}
M.state = state

local function rel(path)
  local root = state.repo and state.repo.root
  if not root then return nil end
  if root == "/" then return path:sub(2) end
  if path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
  return nil
end
M.rel = rel

function M.abs(relpath)
  local root = state.repo.root
  return (root == "/" and "" or root) .. "/" .. relpath
end

-- Opens the repository holding dir (none: the git features stay off).
function M.open(dir)
  state.repo = nil
  local okk, repo = pcall(git.open, dir)
  if okk then state.repo = repo end
  return state.repo ~= nil
end

function M.available()
  return state.repo ~= nil
end

-- Reads the status again: files[path] = "M", "A", "D" or "U" (untracked).
function M.refresh()
  if not state.repo then return end
  local okk, st = pcall(git.status, state.repo)
  if not okk then
    state.err = tostring(st)
    return
  end
  state.err = nil
  state.branch = git.branch(state.repo)
  state.staged, state.unstaged, state.untracked = st.staged, st.unstaged, st.untracked
  local files, dirs = {}, {}
  local function set(path, kind)
    local abs = M.abs(path)
    files[abs] = files[abs] or kind
    local d = abs:match("^(.*)/[^/]*$")
    while d and d ~= "" and not dirs[d] do
      dirs[d] = kind == "U" and "U" or "M"
      d = d:match("^(.*)/[^/]*$")
    end
  end
  for _, e in ipairs(st.unstaged) do set(e.path, e.kind == "deleted" and "D" or "M") end
  for _, e in ipairs(st.staged) do set(e.path, e.kind == "new file" and "A" or e.kind == "deleted" and "D" or "M") end
  for _, e in ipairs(st.untracked) do set(e.path, "U") end
  state.files, state.dirs = files, dirs
  state.headCache = {}
end

-- The state of a path, for the explorer.
function M.fileState(path, isDir)
  if isDir then return state.dirs[path] end
  return state.files[path]
end

-- Counts for the status bar: staged, changed (unstaged + untracked).
function M.counts()
  return #state.staged, #state.unstaged + #state.untracked
end

-- Gutter marks of buffer b, against the file as HEAD has it.
function M.marks(b)
  if not state.repo or not b.path then return {} end
  local r = rel(b.path)
  if not r then return {} end
  state.headCache = state.headCache or {}
  local head = state.headCache[r]
  if head == nil then
    local okk, text = pcall(git.headtext, state.repo, r, 256 * 1024)
    head = okk and text or false
    state.headCache[r] = head
  end
  if not head then
    if state.files[b.path] == "U" or state.files[b.path] == "A" then
      local m = {}
      for i = 1, #b.lines do m[i] = "+" end
      return m
    end
    return {}
  end
  return diff.marks(head, b.lines)
end

-- ------------------------------------------------------------------ changes

local function run(fn, ...)
  local okk, err = pcall(fn, state.repo, ...)
  M.refresh()
  if not okk then return nil, tostring(err) end
  return true
end

function M.stage(relpath) return run(git.add, {relpath}) end
function M.stageAll() return run(git.add, {""}) end
function M.unstage(relpath) return run(git.unstage, {relpath}) end
function M.discard(relpath) return run(git.discard, {relpath}) end

-- A diff of a file as text (lines starting with " ", "-", "+" or "@"):
-- staged: HEAD -> index, otherwise index -> working tree.
function M.diffText(relpath, staged)
  local repo = state.repo
  local old, new
  if staged then
    old = git.headtext(repo, relpath, 256 * 1024)
    new = git.indextext(repo, relpath, 256 * 1024)
  else
    old = git.indextext(repo, relpath, 256 * 1024)
    new = host.fs.read(M.abs(relpath))
  end
  local edits = diff.edits(old or "", new or "")
  local out = {"@ " .. relpath .. (staged and " (staged)" or "")}
  for _, e in ipairs(edits) do out[#out + 1] = e[1] .. e[2] end
  return table.concat(out, "\n")
end

-- The rows of the GIT panel: {title} headers and {path, kind, staged} files.
function M.rows()
  local rows = {}
  local function section(title, list, staged)
    if #list == 0 then return end
    rows[#rows + 1] = {title = title .. " (" .. #list .. ")"}
    for _, e in ipairs(list) do
      rows[#rows + 1] = {path = e.path, kind = e.kind, staged = staged}
    end
  end
  section("STAGED", state.staged, true)
  section("CHANGES", state.unstaged, false)
  section("UNTRACKED", state.untracked, false)
  return rows
end

-- Quotes a shell argument.
function M.quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

return M
