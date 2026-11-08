-- code.gitcli: the functions of the firmware's git.cmd that the editor uses,
-- through the git command of a computer (git status --porcelain...). Paths
-- are relative to the repository root; errors are raised as strings.
local M = {}

local function quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Output of a git command in the repository, and whether it succeeded.
local function git(root, args)
  local h = io.popen("git -C " .. quote(root) .. " " .. args .. " 2>&1")
  if not h then return "", false end
  local out = h:read("a") or ""
  local ok = h:close()
  return out, ok == true
end

local function fail(out)
  error((out:gsub("%s+$", "")), 0)
end

-- The repository holding dir.
function M.open(dir)
  local out, ok = git(dir, "rev-parse --show-toplevel")
  if not ok then fail(out) end
  return {root = (out:gsub("%s+$", ""))}
end

function M.branch(repo)
  local out, ok = git(repo.root, "symbolic-ref --short -q HEAD")
  if not ok then return nil end
  return (out:gsub("%s+$", ""))
end

local STAGED = {A = "new file", D = "deleted", M = "modified", R = "modified", C = "modified", T = "modified"}

-- {staged, unstaged, untracked}: lists of {kind, path}, as git.cmd gives them.
function M.status(repo)
  local out, ok = git(repo.root, "status --porcelain=v1 -z -uall")
  if not ok then fail(out) end
  local st = {staged = {}, unstaged = {}, untracked = {}}
  local fields = {}
  for f in out:gmatch("([^%z]*)%z") do fields[#fields + 1] = f end
  local i = 1
  while i <= #fields do
    local f = fields[i]
    local x, y, path = f:sub(1, 1), f:sub(2, 2), f:sub(4)
    if x == "R" or x == "C" then i = i + 1 end  -- the old name follows
    if x == "?" then
      st.untracked[#st.untracked + 1] = {kind = "", path = path}
    else
      if STAGED[x] then st.staged[#st.staged + 1] = {kind = STAGED[x], path = path} end
      if y == "M" or y == "T" then st.unstaged[#st.unstaged + 1] = {kind = "modified", path = path}
      elseif y == "D" then st.unstaged[#st.unstaged + 1] = {kind = "deleted", path = path} end
    end
    i = i + 1
  end
  for _, l in pairs(st) do table.sort(l, function(a, b) return a.path < b.path end) end
  return st
end

-- A file as HEAD has it, or nil.
function M.headtext(repo, path)
  local out, ok = git(repo.root, "show " .. quote("HEAD:" .. path))
  return ok and out or nil
end

-- A file as the index has it, or nil.
function M.indextext(repo, path)
  local out, ok = git(repo.root, "show " .. quote(":" .. path))
  return ok and out or nil
end

local function each(paths)
  local q = {}
  for _, p in ipairs(paths) do q[#q + 1] = quote(p == "" and "." or p) end
  return table.concat(q, " ")
end

function M.add(repo, paths)
  local out, ok = git(repo.root, "add -A -- " .. each(paths))
  if not ok then fail(out) end
end

function M.unstage(repo, paths)
  local out, ok = git(repo.root, "reset -q -- " .. each(paths))
  if not ok then fail(out) end
end

function M.discard(repo, paths)
  local out, ok = git(repo.root, "checkout -- " .. each(paths))
  if not ok then fail(out) end
end

return M
