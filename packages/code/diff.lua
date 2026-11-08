-- code.diff: line diff (Myers), for the git gutter and the diff view. The
-- same as the firmware's git.diff, without its printing (which needs
-- Termina), so that it runs anywhere.
local M = {}

local MAX_D = 60  -- beyond that, everything removed then everything added

local function split(text)
  local out = {}
  if text == "" then return out end
  for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end
M.split = split

-- Edit script between a and b: list of {op = " "|"-"|"+", line}.
local function myers(a, b, lo, ahi, bhi)
  local n, m = ahi - lo, bhi - lo
  local v, trace = {[1] = 0}, {}
  local found
  for d = 0, math.min(n + m, MAX_D) do
    local copy = {}
    for k, x in pairs(v) do copy[k] = x end
    trace[d] = copy
    for k = -d, d, 2 do
      local x
      if k == -d or (k ~= d and (v[k - 1] or -1) < (v[k + 1] or -1)) then x = v[k + 1] or 0
      else x = (v[k - 1] or 0) + 1 end
      local y = x - k
      while x < n and y < m and a[lo + x + 1] == b[lo + y + 1] do x, y = x + 1, y + 1 end
      v[k] = x
      if x >= n and y >= m then found = d break end
    end
    if found then break end
  end
  local edits = {}
  if not found then
    for i = lo + 1, ahi do edits[#edits + 1] = {"-", a[i]} end
    for i = lo + 1, bhi do edits[#edits + 1] = {"+", b[i]} end
    return edits
  end
  local x, y = n, m
  for d = found, 0, -1 do
    local vd = trace[d]
    local k = x - y
    local pk
    if k == -d or (k ~= d and (vd[k - 1] or -1) < (vd[k + 1] or -1)) then pk = k + 1 else pk = k - 1 end
    local px = vd[pk] or 0
    local py = px - pk
    while x > px and y > py do
      edits[#edits + 1] = {" ", a[lo + x]}
      x, y = x - 1, y - 1
    end
    if d > 0 then
      if x == px then edits[#edits + 1] = {"+", b[lo + y]} else edits[#edits + 1] = {"-", a[lo + x]} end
    end
    x, y = px, py
  end
  local out = {}
  for i = #edits, 1, -1 do out[#out + 1] = edits[i] end
  return out
end

-- Edit script between two texts (strings, or tables of lines).
function M.edits(old, new)
  if type(old) ~= "table" then old = split(old or "") end
  if type(new) ~= "table" then new = split(new or "") end
  -- common prefix and suffix first
  local pre = 0
  while pre < #old and pre < #new and old[pre + 1] == new[pre + 1] do pre = pre + 1 end
  local suf = 0
  while suf < #old - pre and suf < #new - pre and old[#old - suf] == new[#new - suf] do suf = suf + 1 end
  local edits = {}
  for i = 1, pre do edits[#edits + 1] = {" ", old[i]} end
  for _, e in ipairs(myers(old, new, pre, #old - suf, #new - suf)) do edits[#edits + 1] = e end
  for i = #old - suf + 1, #old do edits[#edits + 1] = {" ", old[i]} end
  return edits
end

-- Changes seen from the new text, for a gutter: marks[n] is "+" (line n
-- added), "~" (changed) or "-" (lines removed right after line n; marks[0]:
-- at the top).
function M.marks(old, new)
  local marks, bline = {}, 0
  local edits = M.edits(old, new)
  local i = 1
  while i <= #edits do
    if edits[i][1] == " " then
      bline, i = bline + 1, i + 1
    else
      local minus, plus = 0, 0
      while i <= #edits and edits[i][1] ~= " " do
        if edits[i][1] == "-" then minus = minus + 1 else plus = plus + 1 end
        i = i + 1
      end
      for k = 1, plus do marks[bline + k] = k <= minus and "~" or "+" end
      if plus == 0 then marks[bline] = "-" end
      bline = bline + plus
    end
  end
  return marks
end

return M
