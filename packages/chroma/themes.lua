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
  -- Neon city at night: blue-black background, cool pale text, acid yellow,
  -- electric cyan, hot magenta and warning red.
  { name = "cyberpunk", colors = {
      0x0A0A12, 0x2D5BFF, 0x00C76A, 0x00B8D4, 0xE0002E, 0xD4009B, 0xD4A000, 0xC8D8E0,
      0x3A3A55, 0x5C8DFF, 0x39FF14, 0x00F0FF, 0xFF2A5A, 0xFF00C8, 0xFCEE0A, 0xF0FAFF,
  } },
  -- Ethan Schoonover's Solarized, dark. The original puts grays on the
  -- bright half; here the eight accents fill both halves (the bright one a
  -- little lighter), as programs use the bright colors for emphasis.
  { name = "solarized", colors = {
      0x002B36, 0x268BD2, 0x859900, 0x2AA198, 0xDC322F, 0xD33682, 0xCB4B16, 0x839496,
      0x586E75, 0x6CA6E8, 0xA8BF2A, 0x4FD1C0, 0xF2574F, 0xE65FA0, 0xB58900, 0xEEE8D5,
  } },
  -- Gruvbox dark: warm browns and cream, faded then bright accents.
  { name = "gruvbox", colors = {
      0x282828, 0x458588, 0x98971A, 0x689D6A, 0xCC241D, 0xB16286, 0xD65D0E, 0xD5C4A1,
      0x928374, 0x83A598, 0xB8BB26, 0x8EC07C, 0xFB4934, 0xD3869B, 0xFABD2F, 0xFBF1C7,
  } },
  -- The Commodore 64 at power on: light blue on dark blue. Its own colors
  -- are dim on that blue, so the dark ones are lifted a little.
  { name = "c64", colors = {
      0x352879, 0x6C5EB5, 0x588D43, 0x70A4B2, 0x9A6759, 0x8F4FAE, 0xA0702F, 0x8D80D8,
      0x8C8C8C, 0x8E80E8, 0x9AD284, 0x9FE0EE, 0xD08070, 0xC080E0, 0xEEEE77, 0xFFFFFF,
  } },
  -- Dracula: purple-gray night, pastel neon.
  { name = "dracula", colors = {
      0x282A36, 0xBD93F9, 0x50FA7B, 0x8BE9FD, 0xFF5555, 0xFF79C6, 0xFFB86C, 0xF8F8F2,
      0x6272A4, 0xD6ACFF, 0x69FF94, 0xA4FFFF, 0xFF6E6E, 0xFF92DF, 0xF1FA8C, 0xFFFFFF,
  } },
  -- Tokyo Night: ink blue, soft lavender text, city lights.
  { name = "tokyonight", colors = {
      0x1A1B26, 0x3D59A1, 0x9ECE6A, 0x2AC3DE, 0xF7768E, 0xBB9AF7, 0xFF9E64, 0xA9B1D6,
      0x565F89, 0x7AA2F7, 0xB9F27C, 0x7DCFFF, 0xFF7A93, 0xD7B8FF, 0xE0AF68, 0xC0CAF5,
  } },
}
