-- theme: the screen's color theme, remembered across restarts.
--   theme          lists the themes, * on the current one, with a sample
--   theme <name>   switches to that theme
-- The themes are in chroma.themes (themes.lua next to this file).
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
if name then
  for _, t in ipairs(themes) do
    if t.name == name then
      palette.set(t)
      return
    end
  end
  print("Unknown theme.")
  return
end

local current = palette.get().name
local names = {}
for _, t in ipairs(themes) do names[#names + 1] = t.name .. (t.name == current and "*" or "") end
print("Themes: " .. table.concat(names, " "))
sample()
