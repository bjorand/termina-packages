-- orbit.gemtext: turns a text/gemini page (or plain text) into screen lines.
-- Gemtext is line based: "=> url label" links, "#", "##", "###" headings,
-- "* " list items, "> " quotes, and ``` toggling preformatted blocks, which
-- are shown as-is (cut at the screen edge) instead of wrapped.
local M = {}

-- Colors (background * 16 + foreground).
M.ATTR = {
  text = 0x07, h1 = 0x0E, h2 = 0x0B, h3 = 0x0F, link = 0x0B, visited = 0x05,
  list = 0x07, quote = 0x08, pre = 0x0A,
}

-- Text that is not valid UTF-8 is taken as Latin-1. Tabs become spaces and
-- other control characters go away.
function M.clean(s)
  s = s:gsub("\r", ""):gsub("\t", "    "):gsub("[%z\1-\31\127]", "")
  if utf8.len(s) then return s end
  return (s:gsub("[\128-\255]", function(c) return utf8.char(c:byte()) end))
end

local function len(s) return utf8.len(s) or #s end

-- First n characters of s.
function M.cut(s, n)
  if n <= 0 then return "" end
  local i = utf8.offset(s, n + 1)
  return i and s:sub(1, i - 1) or s
end

-- Splits s into lines of at most width characters, at spaces when possible.
-- The first line starts with first, the next ones with an indent of the
-- same width.
local function wrap(s, width, first, out)
  local indent = string.rep(" ", len(first))
  local avail = width - len(first)
  if avail < 10 then first, indent, avail = "", "", width end
  local line, n, prefix = {}, 0, first
  local function flush()
    out[#out + 1] = prefix .. table.concat(line, " ")
    line, n, prefix = {}, 0, indent
  end
  for word in s:gmatch("%S+") do
    local w = len(word)
    while w > avail do  -- a word longer than the line: cut it
      if n > 0 then flush() end
      local piece = M.cut(word, avail)
      line[1], n = piece, avail
      flush()
      word = word:sub(#piece + 1)
      w = len(word)
    end
    if n > 0 and n + 1 + w > avail then flush() end
    if w > 0 then
      line[#line + 1] = word
      n = n + (n > 0 and 1 or 0) + w
    end
  end
  if n > 0 or #out == 0 then flush() end
end

-- layout(text, width, gemini) -> lines, links, title.
-- lines[i] = {text, attr, link = index in links}. links[i] = {url, label, line}.
function M.layout(text, width, gemini)
  local lines, links, title = {}, {}, nil
  local pre = false
  local function add(s, attr, link)
    lines[#lines + 1] = {text = s, attr = attr, link = link}
  end
  local function wrapped(s, attr, first, link)
    local out = {}
    wrap(s, width, first, out)
    for _, l in ipairs(out) do add(l, attr, link) end
  end
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = M.clean(raw)
    if not gemini then
      if line == "" then add("", M.ATTR.text) else wrapped(line, M.ATTR.text, "") end
    elseif line:sub(1, 3) == "```" then
      pre = not pre
    elseif pre then
      add(M.cut(line, width), M.ATTR.pre)
    elseif line:sub(1, 2) == "=>" then
      local url, label = line:match("^=>%s*(%S+)%s*(.*)$")
      if url then
        if label == "" then label = url end
        local n = #links + 1
        links[n] = {url = url, label = label, line = #lines + 1}
        wrapped(label, M.ATTR.link, "\u{2192} ", n)
      end
    elseif line:sub(1, 3) == "###" then
      wrapped(line:sub(4):match("^%s*(.-)$"), M.ATTR.h3, "")
    elseif line:sub(1, 2) == "##" then
      wrapped(line:sub(3):match("^%s*(.-)$"), M.ATTR.h2, "")
    elseif line:sub(1, 1) == "#" then
      local h = line:sub(2):match("^%s*(.-)$")
      title = title or h
      wrapped(h, M.ATTR.h1, "")
      add(string.rep("\u{2550}", math.min(len(h), width)), M.ATTR.h1)
    elseif line:sub(1, 2) == "* " then
      wrapped(line:sub(3), M.ATTR.list, "\u{2022} ")
    elseif line:sub(1, 1) == ">" then
      wrapped(line:sub(2):match("^%s*(.-)$"), M.ATTR.quote, "\u{2502} ")
    elseif line == "" then
      add("", M.ATTR.text)
    else
      wrapped(line, M.ATTR.text, "")
    end
  end
  while #lines > 0 and lines[#lines].text == "" do lines[#lines] = nil end
  return lines, links, title
end

return M
