-- code.pipevt: the terminal panel where termina.vt does not exist. Same
-- methods as a vt, but a command runs through io.popen until it ends (its
-- output appears as it comes, it gets no keyboard and Ctrl+C cannot stop
-- it), and escape sequences in its output are dropped.
local host = require "code.host"
local lfs = require "lfs"

local M = {}
local V = {}
V.__index = V

local MAX_LINES = 500

-- progress(): called while a command runs, to show its output.
function M.open(cols, rows, progress)
  return setmetatable({cols = cols, rows = rows, lines = {""}, back = 0, dirty = true,
    progress = progress}, V)
end

local function quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function V:write(s)
  s = s:gsub("\27%[[%d;?]*[%a@`~]", ""):gsub("\27%].-\7", ""):gsub("\r", ""):gsub("\t", "    ")
  local lines = self.lines
  for part, nl in s:gmatch("([^\n]*)(\n?)") do
    lines[#lines] = lines[#lines] .. part
    if nl ~= "" then
      lines[#lines + 1] = ""
      if #lines > MAX_LINES + self.rows then table.remove(lines, 1) end
    end
    if part == "" and nl == "" then break end
  end
  self.dirty = true
end

-- The text of row r of the view (0 = top).
function V:line(r)
  local first = math.max(1, #self.lines - self.rows + 1 - self.back)
  return self.lines[first + r]
end

function V:draw(x, y, w, h)
  w = math.min(w or self.cols, self.cols)
  h = math.min(h or self.rows, self.rows)
  for r = 0, h - 1 do host.term.putattr(x, y + r, self:line(r) or "", "\7", w, 7) end
  self.dirty = false
end

function V:changed() return self.dirty end

function V:cursor()
  if self.back > 0 then return nil, nil, false end
  local first = math.max(1, #self.lines - self.rows + 1)
  return utf8.len(self.lines[#self.lines]) or 0, #self.lines - first, true
end

function V:size()
  return self.cols, self.rows, math.max(0, #self.lines - self.rows)
end

function V:scroll(n)
  if n == false then self.back = 0
  elseif n then self.back = self.back + n end
  self.back = math.max(0, math.min(self.back, math.max(0, #self.lines - self.rows)))
  self.dirty = true
  return self.back
end

function V:resize(c, r)
  self.cols, self.rows = c, r
  self.dirty = true
end

function V:clear()
  self.lines, self.back, self.dirty = {""}, 0, true
end

-- Runs the command line until it ends; returns 1 (there is no pid).
function V:spawn(line, cwd)
  -- the whole line, its errors included, without the keyboard; Termina's
  -- io.popen takes one command, hence sh -c there
  local cmd = host.termina and ("sh -c " .. quote(line) .. " 2>&1") or ("(" .. line .. ") 2>&1 </dev/null")
  local was = lfs.currentdir()
  if cwd then lfs.chdir(cwd) end
  local h = io.popen(cmd)
  if cwd then lfs.chdir(was) end
  if not h then return nil, "cannot run the command" end
  self.status = nil
  local shown = host.sys.millis()
  for l in h:lines("L") do
    self:write(l)
    if self.progress and host.sys.millis() - shown > 100 then
      self.progress()
      shown = host.sys.millis()
    end
  end
  local ok, _, code = h:close()
  self.status = ok and 0 or (code or 1)
  return 1
end

function V:job()
  if not self.status then return nil end
  return "done", self.status
end

function V:kill() return false end
function V:close() end

return M
