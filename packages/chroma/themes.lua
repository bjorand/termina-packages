-- chroma.themes: the themes, in the order the theme command lists them.
-- Each is what termina.palette.set takes:
--   tint = 0xRRGGBB    a monochrome monitor of that phosphor color, or
--   colors = {16}      the 16 colors, in CGA order: black, blue, green,
--                      cyan, red, magenta, brown, light gray, then the
--                      bright ones. Color 0 is the background, 7 the text.
-- Another program can use them: local themes = require "chroma.themes"
return {
  { name = "green", tint = 0x33FF66 },
  { name = "amber", tint = 0xFFB000 },
  { name = "white", tint = 0xDDE6FF },
  { name = "cga", colors = {
      0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
      0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
  } },
  -- Neon on a night sky: deep indigo background, lavender text, cyan, hot
  -- pink and a setting sun's orange and yellow.
  { name = "synthwave", colors = {
      0x1A1033, 0x3B2E8C, 0x2DE2A6, 0x36F9F6, 0xFE4450, 0xC94FD6, 0xFF8B39, 0xD6C7F0,
      0x5A4A87, 0x7B6CFF, 0x72F1B8, 0x8BFFFF, 0xFF6E96, 0xFF2E97, 0xFEDE5D, 0xFFFFFF,
  } },
}
