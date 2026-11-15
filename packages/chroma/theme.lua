-- theme: the screen's color theme, remembered across restarts.
--   theme          picks one in a list, the whole screen previewing it
--                  (keys: Up/Down or the mouse preview, Enter keeps it,
--                  Q or Esc goes back to the theme of before)
--   theme list     lists the themes, * on the current one, with a sample
--   theme <name>   switches to that theme
-- The themes are in chroma.themes (themes.lua next to this file).
local term, key, sys = termina.term, termina.key, termina.sys
local palette = termina.palette
if not palette then
  print("This theme needs TERMINA 8.3.0 or later (termina.palette).")
  return
end
local themes = require "chroma.themes"

-- A row of the 16 colors in CGA order, as backgrounds (ANSI numbers them in
-- another order: CGA's blue is ANSI's 4).
local CGA_TO_ANSI = { 0, 4, 2, 6, 1, 5, 3, 7 }
local function sample()
  local row = {}
  for c = 0, 15 do
    local base = c < 8 and 40 or 100
    row[#row + 1] = string.format("\27[%dm  ", base + CGA_TO_ANSI[c % 8 + 1])
  end
  print(table.concat(row) .. "\27[0m")
end

local name = arg[1]
if name == "list" then
  local current = palette.get().name
  local names = {}
  for _, t in ipairs(themes) do names[#names + 1] = t.name .. (t.name == current and "*" or "") end
  print("Themes: " .. table.concat(names, " "))
  sample()
  return
elseif name then
  for _, t in ipairs(themes) do
    if t.name == name then
      palette.set(t)
      return
    end
  end
  print("Unknown theme. The themes: theme list")
  return
end

-- ------------------------------------------------------------ the picker

local COLS, ROWS = term.cols(), term.rows()
local HEAD = 1 * 16 + 15          -- header and footer: white on blue
local TEXT, DIM, BRIGHT = 0x07, 0x08, 0x0F
local SEL = 0x1F
local GREEN, CYAN, RED, MAGENTA, YELLOW = 0x0A, 0x0B, 0x0C, 0x0D, 0x0E
local BLUE = 0x09

-- The palette in use when the picker started, in the form preview() takes
-- (get() gives tint = 0 for a palette of colors).
local before = palette.get()
local restore = before.tint ~= 0 and { name = before.name, tint = before.tint }
  or { name = before.name, colors = before.colors }

local sel = 1
for i, t in ipairs(themes) do
  if t.name == before.name then sel = i end
end

local function put(x, y, s, attr) return term.put(x, y, s, attr or TEXT) end

-- A rounded frame with a title, cleared inside.
local function box(x, y, w, h, title)
  put(x, y, "╭" .. string.rep("─", w - 2) .. "╮", DIM)
  for i = 1, h - 2 do
    put(x, y + i, "│" .. string.rep(" ", w - 2) .. "│", DIM)
  end
  put(x, y + h - 1, "╰" .. string.rep("─", w - 2) .. "╯", DIM)
  if title then put(x + 2, y, " " .. title .. " ", BRIGHT) end
end

local LIST_W = 18
local TOP = 3                                   -- first row of the boxes
local BOX_H = math.min(ROWS - 2 - TOP, math.max(#themes + 2, 24))
local PX = LIST_W + 1                           -- the preview box
local PW = COLS - PX

-- Draws a run of {text, attr} pairs from x on row y.
local function spans(x, y, list)
  for _, s in ipairs(list) do x = x + put(x, y, s[1], s[2]) end
end

local function header()
  term.fill(1, " ", HEAD)
  local x = put(0, 1, " ◆ THEMES ", 0x2F)
  put(x, 1, "\u{E0B0}", 0x21)
  local right = #themes .. " themes, chroma"
  put(COLS - 1 - #right, 1, right, HEAD)
end

local function footer()
  term.fill(ROWS - 1, " ", HEAD)
  put(1, ROWS - 1, "↑↓ Preview  Enter Keep  Esc Cancel", HEAD)
end

local function list()
  for i, t in ipairs(themes) do
    local y = TOP + i
    if y >= TOP + BOX_H - 1 then break end
    local chosen = i == sel
    local a = chosen and SEL or TEXT
    put(1, y, string.rep(" ", LIST_W - 2), a)
    put(2, y, t.name == before.name and "●" or " ", chosen and SEL or GREEN)
    put(4, y, t.name, a)
    if t.tint then put(LIST_W - 6, y, "mono", chosen and SEL or DIM) end
  end
end

local function gauge(pct, w)
  local full = pct * w // 100
  return string.rep("█", full) .. string.rep("░", w - full)
end

-- What programs look like in this palette: the 16 colors, a shell, some
-- Lua as the editor colors it, gauges and messages.
local function preview()
  box(PX, TOP, PW, BOX_H, "Preview: " .. themes[sel].name)
  local x, y = PX + 2, TOP + 2
  for c = 0, 7 do
    put(x + 3 * c, y, "   ", c * 16)
    put(x + 3 * c, y + 1, "   ", (c + 8) * 16)
  end
  put(x, y + 2, "0  1  2  3  4  5  6  7  +8", DIM)

  y = y + 4
  spans(x, y, { { "ada@termina", GREEN }, { ":", TEXT }, { "~/src", BLUE }, { "$ ", BRIGHT }, { "ls", TEXT } })
  spans(x, y + 1, { { "README.md  ", TEXT }, { "games/  ", BLUE }, { "run.sh", GREEN } })

  y = y + 3
  spans(x, y, { { "-- count to three", DIM } })
  spans(x, y + 1, { { "local", MAGENTA }, { " n = ", TEXT }, { "3", YELLOW } })
  spans(x, y + 2, { { "for", MAGENTA }, { " i = ", TEXT }, { "1", YELLOW }, { ", n ", TEXT }, { "do", MAGENTA } })
  spans(x, y + 3, { { "  ", TEXT }, { "print", CYAN }, { "(", TEXT }, { "\"hi \"", 0x02 }, { " .. i)", TEXT } })
  spans(x, y + 4, { { "end", MAGENTA } })

  y = y + 6
  local gw = math.max(4, math.min(16, PW - 14))
  spans(x, y, { { "CPU  ", DIM }, { gauge(30, gw), GREEN }, { " 30%", TEXT } })
  spans(x, y + 1, { { "Mem  ", DIM }, { gauge(65, gw), YELLOW }, { " 65%", TEXT } })
  spans(x, y + 2, { { "Disk ", DIM }, { gauge(90, gw), RED }, { " 90%", TEXT } })

  y = y + 4
  put(x, y, "✓ Saved", GREEN)
  put(x, y + 1, "! Battery low", YELLOW)
  put(x, y + 2, "✗ Not found", RED)
  put(x, y + 3, " Selected line ", SEL)
end

local function draw()
  term.attr(TEXT)
  term.cls()
  header()
  box(0, TOP, LIST_W, BOX_H, "Themes")
  list()
  preview()
  footer()
end

local function choose(i)
  if i < 1 or i > #themes or i == sel then return end
  sel = i
  palette.preview(themes[sel])
  list()
  preview()
end

-- The loop; returns the theme to keep, or nil to go back to the one of before.
local function run()
  draw()
  while true do
    local e = key.wait()
    if e.type == "char" then
      local c = e.ch:lower()
      if c == "q" then return nil end
      if c == "k" then choose(sel - 1) elseif c == "j" then choose(sel + 1) end
    elseif e.type == "key" then
      local k = e.key
      if k == "esc" then return nil
      elseif k == "enter" then return themes[sel]
      elseif k == "up" then choose(sel - 1)
      elseif k == "down" then choose(sel + 1)
      elseif k == "home" or k == "pgup" then choose(1)
      elseif k == "end" or k == "pgdn" then choose(#themes)
      end
    elseif e.type == "wheel" then
      choose(sel + (e.n > 0 and -1 or 1))
    elseif e.type == "mouse" and e.down and e.x < LIST_W then
      local i = e.y - TOP
      if i == sel then return themes[sel] end   -- a second click keeps it
      choose(i)
    end
  end
end

local saved = term.attr()
term.showcursor(false)
sys.saver(false)
palette.preview(themes[sel])
local ok, picked = pcall(run)
if ok and picked then
  palette.set(picked)
else
  palette.preview(restore)
end
term.attr(saved)
term.cls()
term.showcursor(true)
if not ok then error(picked, 0) end
if picked then print("Theme: " .. picked.name) end
