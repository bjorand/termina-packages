-- nightstand.font: the big clock digits. Seven rounded strokes that join at
-- the corners, drawn with boxes and discs, so that they stay smooth at any
-- size instead of showing doubled dots.
local M = {}

M.W, M.H, M.T = 96, 176, 21  -- digit width, height, stroke (odd: round ends)
M.SP, M.COLON = 24, 56       -- space between digits, width of ':'

--   a
-- f   b
--   g
-- e   c
--   d
local SEG = {
  ["0"] = "abcdef", ["2"] = "abged", ["3"] = "abgcd", ["4"] = "fgbc",
  ["5"] = "afgcd", ["6"] = "afgedc", ["7"] = "abc", ["8"] = "abcdefg",
  ["9"] = "abcdfg", ["-"] = "g",
}

-- Box with round ends, along its longer side.
local function cap(s, x, y, w, h, c)
  if w >= h then
    local r = h // 2
    s:box(x + r, y, w - 2 * r, h, c)
    s:circle(x + r, y + r, r, c, true)
    s:circle(x + w - r - 1, y + r, r, c, true)
  else
    local r = w // 2
    s:box(x, y + r, w, h - 2 * r, c)
    s:circle(x + r, y + r, r, c, true)
    s:circle(x + r, y + h - r - 1, r, c, true)
  end
end

local function digit(s, x, y, ch, c)
  local W, H, T = M.W, M.H, M.T
  local r, half = T // 2, H // 2
  if ch == "1" then  -- one centered stroke and its slanted flag
    local cx = x + W // 2 + 8
    cap(s, cx - r, y, T, H, c)
    for k = 0, 30, 3 do s:circle(cx - k, y + r + k * 3 // 4, r, c, true) end
    return
  end
  local on = SEG[ch]
  if not on then return end
  local function has(k) return on:find(k, 1, true) end
  if has("a") then cap(s, x, y, W, T, c) end
  if has("g") then cap(s, x, y + half - r, W, T, c) end
  if has("d") then cap(s, x, y + H - T, W, T, c) end
  if has("f") then cap(s, x, y, T, half + r + 1, c) end
  if has("b") then cap(s, x + W - T, y, T, half + r + 1, c) end
  if has("e") then cap(s, x, y + half - r, T, H - half + r, c) end
  if has("c") then cap(s, x + W - T, y + half - r, T, H - half + r, c) end
end

-- The two dots of ':' at x, in color c (0 erases them).
function M.colon(s, x, y, c)
  local cx, r = x + M.COLON // 2, M.T // 2
  s:circle(cx, y + M.H * 3 // 10, r, c, true)
  s:circle(cx, y + M.H * 7 // 10, r, c, true)
end

local function advance(str, i)
  local ch, nx = str:sub(i, i), str:sub(i + 1, i + 1)
  if ch == ":" then return M.COLON end
  return (nx == "" or nx == ":") and M.W or M.W + M.SP
end

function M.width(str)
  local w = 0
  for i = 1, #str do w = w + advance(str, i) end
  return w
end

-- Draws str ("12:34") at x, y; returns the x of each ':' found.
function M.draw(s, x, y, str, c)
  local colons = {}
  for i = 1, #str do
    local ch = str:sub(i, i)
    if ch == ":" then
      colons[#colons + 1] = x
      M.colon(s, x, y, c)
    else
      digit(s, x, y, ch, c)
    end
    x = x + advance(str, i)
  end
  return colons
end

return M
