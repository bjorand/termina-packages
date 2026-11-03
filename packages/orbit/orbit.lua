-- orbit: a browser for Gemini capsules, the small web of gemini:// URLs.
--   orbit                         start page
--   orbit geminiprotocol.net/docs/
-- Keys: Tab / Shift+Tab select a link, Enter opens it, Backspace goes back,
-- G types an address, U goes up one level, R reloads, B bookmarks the page,
-- Shift+B lists the bookmarks, H help, Q or Esc quits.
-- Pages up to 256 KB are read; other files can be saved to the filesystem.
local proto = require "orbit.proto"
local gemtext = require "orbit.gemtext"

local HOME = "gemini://geminiprotocol.net/"
local BOOKMARKS = proto.DIR .. "/bookmarks.gmi"
local MAX_PAGE = 256 * 1024
local MAX_REDIRECTS = 5
local MAX_HISTORY = 20
local WHEEL_LINES = 3

local major, minor = (sys.version() or ""):match("^(%d+)%.(%d+)")
if not major or tonumber(major) * 100 + tonumber(minor) < 206 then
  print("orbit needs TERMINA 2.6.0 or later (TLS sockets), this is " .. (sys.version() or "?"))
  return
end

local COLS, ROWS = term.cols(), term.rows()
local TOP, BOTTOM = 2, ROWS - 2       -- content rows; row 1: address, last: footer
local HEIGHT = BOTTOM - TOP + 1
local BAR, FOOT, SELECTED = 0x1F, 0x70, 0x3F

local page              -- {url, lines, links, title, top, sel, warn}
local history = {}      -- {url, top, sel} of the pages before this one
local visited = {}

-- ------------------------------------------------------------------- drawing

local function fit(s, n)
  local w = utf8.len(s) or #s
  if w > n then return gemtext.cut(s, n - 1) .. "\u{2026}" end
  return s .. string.rep(" ", n - w)
end

local function footer(s)
  term.fill(ROWS - 1, " ", FOOT)
  term.put(0, ROWS - 1, fit(s or "", COLS), FOOT)
end

local function help()
  local where = ""
  if page and #page.lines > HEIGHT then
    where = string.format(" %d%%", math.min(100, (page.top + HEIGHT) * 100 // #page.lines))
  end
  local keys = page and page.warn and "A accept the new certificate  Backspace back  Q quit"
    or "Tab link  Enter open  Bksp back  G go  R reload  B mark  H help  Q quit"
  footer(fit(keys, COLS - #where) .. where)
end

local function draw()
  term.fill(1, " ", BAR)
  term.put(0, 1, fit(page and page.url or "", COLS), BAR)
  for row = 0, HEIGHT - 1 do
    local y = TOP + row
    term.fill(y, " ", 0x07)
    local l = page and page.lines[page.top + row + 1]
    if l then
      local attr = l.attr
      if l.link then
        if l.link == page.sel then attr = SELECTED
        elseif visited[page.links[l.link].abs] then attr = gemtext.ATTR.visited end
      end
      term.put(0, y, l.text, attr)
    end
  end
  help()
end

local function scrollTo(top)
  page.top = math.max(0, math.min(top, #page.lines - HEIGHT))
end

-- One-line editor on the footer row: the text, or nil after Esc.
local function ask(prompt, text, hidden)
  text = text or ""
  term.showcursor(true)
  while true do
    local shown = hidden and string.rep("*", utf8.len(text)) or text
    local room = COLS - (utf8.len(prompt) or #prompt) - 1
    local n = utf8.len(shown) or #shown
    if n > room then shown = shown:sub(utf8.offset(shown, n - room + 1)) n = room end
    footer(prompt .. shown)
    term.cursor((utf8.len(prompt) or #prompt) + n, ROWS - 1)
    local e = key.wait()
    if e.type == "char" then
      if #text < 1024 then text = text .. e.ch end
    elseif e.type == "key" then
      if e.key == "enter" then break
      elseif e.key == "esc" then text = nil break
      elseif e.key == "backspace" and #text > 0 then
        text = text:sub(1, utf8.offset(text, -1) - 1)
      elseif e.ctrl and e.key == "u" then
        text = ""
      end
    end
  end
  term.showcursor(false)
  return text
end

-- ------------------------------------------------------------------- pages

local function makePage(url, text, isGemini)
  local lines, links, title = gemtext.layout(text, COLS, isGemini)
  for _, l in ipairs(links) do l.abs = proto.resolve(url, l.url) end
  return {url = url, lines = lines, links = links, title = title, top = 0}
end

local function errorPage(url, title, text)
  return makePage(url, "# " .. title .. "\n\n" .. (text or ""), true)
end

local STATUS = {
  [40] = "Temporary failure", [41] = "Server unavailable", [42] = "CGI error",
  [43] = "Proxy error", [44] = "Slow down", [50] = "Permanent failure",
  [51] = "Not found", [52] = "Gone", [53] = "Proxy request refused",
  [59] = "Bad request",
}

local function readBookmarks()
  return fs.exists(BOOKMARKS) and fs.read(BOOKMARKS) or ""
end

local function internal(url)
  if url == "about:bookmarks" then
    local marks = readBookmarks()
    if marks == "" then marks = "No bookmarks yet: B adds the page you are reading." end
    return makePage(url, "# Bookmarks\n\n" .. marks, true)
  end
  return makePage("about:help", table.concat({
    "# orbit",
    "A browser for Gemini capsules: gemini:// URLs, served over TLS on port 1965.",
    "",
    "## Keys",
    "* Up, Down, PgUp, PgDn, Space, Home, End, mouse wheel: scroll",
    "* Tab, Shift+Tab: select the next or previous link",
    "* Enter: open the selected link",
    "* Backspace or Left: go back",
    "* G: type an address (gemini:// is optional)",
    "* U: go up one level",
    "* R: reload",
    "* B: bookmark this page; Shift+B: show the bookmarks",
    "* Q or Esc: quit",
    "",
    "## Certificates",
    "Capsules mostly use self-signed certificates. orbit remembers the first certificate it sees for each host, in " .. proto.DIR .. "/known_hosts, and warns when a host shows a different one.",
    "",
    "## Places",
    "=> gemini://geminiprotocol.net/ Project Gemini",
    "=> gemini://geminiprotocol.net/docs/ Gemini documentation",
    "=> gemini://kennedy.gemi.dev/ Kennedy search engine",
    "=> gemini://gemi.dev/cgi-bin/wp.cgi/ Wikipedia",
    "=> gemini://station.martinrue.com/ Station, a Gemini social network",
  }, "\n"), true)
end

local function filename(url)
  local u = proto.parse(url)
  local name = u and u.path:match("([^/]+)$") or ""
  name = name:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  name = name:gsub("[^%w%._%-]", "_")
  return name ~= "" and name or "download"
end

-- fetch(url) -> page, or nil when there is nothing new to show (input
-- cancelled, file saved).
local function fetch(url)
  if url:match("^about:") then return internal(url) end
  local redirects = 0
  while true do
    local r, err, info = proto.open(url, footer)
    if not r then
      if err == "changed" then
        local p = errorPage(url, "Certificate changed",
          "The certificate of " .. info.host .. " is not the one seen before. "
          .. "The capsule may have renewed it, or someone may be in the way.\n\n"
          .. "```\nBefore: " .. info.old:sub(1, 32) .. "\n        " .. info.old:sub(33)
          .. "\nNow:    " .. info.new:sub(1, 32) .. "\n        " .. info.new:sub(33) .. "\n```\n\n"
          .. "Press A to trust the new certificate and load the page.")
        p.warn = info
        return p
      end
      return errorPage(url, "Cannot load the page", err)
    end
    local s = r.status
    if s >= 10 and s < 20 then
      r:close()
      local input = ask(((r.meta ~= "" and r.meta) or "Input") .. ": ", "", s == 11)
      if not input then return nil end
      url = url:gsub("%?.*$", "") .. "?" .. proto.encode(input)
    elseif s >= 20 and s < 30 then
      local mime = (r.meta:match("^%s*([^;%s]+)") or "text/gemini"):lower()
      if mime:sub(1, 5) == "text/" then
        local body, truncated = r:body(MAX_PAGE)
        local p = makePage(url, body, mime == "text/gemini")
        body = nil
        if truncated then
          p.lines[#p.lines + 1] = {text = "", attr = 0x07}
          p.lines[#p.lines + 1] = {text = "[page cut at " .. MAX_PAGE // 1024 .. " KB]", attr = 0x0C}
        end
        return p
      end
      local path = ask(mime .. ", save as: ", "/" .. filename(url))
      if not path or path == "" then
        r:close()
        return nil
      end
      local n, why = r:save(path)
      footer(n and string.format("Saved %s (%d bytes)", path, n) or why)
      key.wait()
      return nil
    elseif s >= 30 and s < 40 then
      r:close()
      redirects = redirects + 1
      if redirects > MAX_REDIRECTS then return errorPage(url, "Too many redirects") end
      url = proto.resolve(url, r.meta)
      if not url:match("^gemini:") then
        return errorPage(url, "Redirect", "The capsule sends you elsewhere:\n=> " .. url)
      end
    elseif s >= 60 and s < 70 then
      r:close()
      return errorPage(url, "Certificate required",
        "This page asks for a client certificate, which orbit does not support yet.\n\n" .. r.meta)
    else
      r:close()
      local name = STATUS[s] or STATUS[s // 10 * 10] or "Error"
      return errorPage(url, string.format("%d %s", s, name), r.meta)
    end
    collectgarbage()
  end
end

local function open(url, push)
  local p = fetch(url)
  if not p then
    draw()
    return false
  end
  if push and page then
    table.insert(history, {url = page.url, top = page.top, sel = page.sel})
    if #history > MAX_HISTORY then table.remove(history, 1) end
  end
  page = nil
  collectgarbage()
  page = p
  visited[p.url] = true
  draw()
  return true
end

local function back()
  local h = table.remove(history)
  if not h then return end
  if not open(h.url, false) then return end
  page.sel = h.sel
  scrollTo(h.top)
  draw()
end

-- -------------------------------------------------------------------- links

local function showLink()
  local l = page.links[page.sel]
  if not l then return end
  if l.line - 1 < page.top or l.line - 1 >= page.top + HEIGHT then
    scrollTo(l.line - 1 - HEIGHT // 3)
  end
end

-- Next (dir = 1) or previous (-1) link; starts from the screen when the
-- selected link is out of sight.
local function selectLink(dir)
  local links = page.links
  if #links == 0 then return end
  local sel = page.sel
  local visible = sel and links[sel].line - 1 >= page.top and links[sel].line - 1 < page.top + HEIGHT
  if visible then
    sel = (sel - 1 + dir) % #links + 1
  elseif dir > 0 then  -- first link on the screen or below it
    sel = #links
    for i, l in ipairs(links) do
      if l.line - 1 >= page.top then sel = i break end
    end
  else  -- last link on the screen or above it
    sel = 1
    for i = #links, 1, -1 do
      if links[i].line - 1 < page.top + HEIGHT then sel = i break end
    end
  end
  page.sel = sel
  showLink()
end

local function addBookmark()
  if page.url:match("^about:") then return end
  local marks = readBookmarks()
  local line = "=> " .. page.url .. " " .. (page.title or page.url)
  if marks:find("=> " .. page.url .. " ", 1, true) then
    footer("Already in the bookmarks")
  else
    fs.mkdir(proto.DIR)
    fs.append(BOOKMARKS, line .. "\n")
    footer("Bookmarked: " .. (page.title or page.url))
  end
  sys.sleep(800)
end

local function up()
  local u = proto.parse(page.url)
  if not u or not u.host then return end
  local path = u.path:gsub("[^/]*/?$", "")
  if path == "" or path == u.path then path = "/" end
  if path == u.path and u.query == "" then return end
  u.path, u.query = path, ""
  open(proto.format(u), true)
end

-- --------------------------------------------------------------------- main

local function run()
  term.cls()
  open(arg[1] and proto.normalize(table.concat(arg, " ")) or HOME, false)
  while true do
    local e = key.wait()
    local k
    if e.type == "char" then k = e.ch
    elseif e.type == "key" and #e.key > 1 then k = e.key end
    if e.type == "wheel" then
      scrollTo(page.top + (e.n > 0 and -WHEEL_LINES or WHEEL_LINES))
      draw()
    elseif k == "q" or k == "Q" or k == "esc" then
      return
    elseif k == "down" then scrollTo(page.top + 1) draw()
    elseif k == "up" then scrollTo(page.top - 1) draw()
    elseif k == "pgdn" or k == " " then scrollTo(page.top + HEIGHT - 1) draw()
    elseif k == "pgup" then scrollTo(page.top - HEIGHT + 1) draw()
    elseif k == "home" then scrollTo(0) draw()
    elseif k == "end" then scrollTo(#page.lines) draw()
    elseif k == "tab" then selectLink(e.shift and -1 or 1) draw()
    elseif k == "enter" then
      local l = page.links[page.sel]
      if l then
        if l.abs:match("^gemini:") or l.abs:match("^about:") then
          open(l.abs, true)
        else
          footer("Not a Gemini link: " .. l.abs)
        end
      end
    elseif k == "backspace" or k == "left" then back()
    elseif k == "g" or k == "G" then
      local url = ask("Go to: ", page.url:match("^about:") and "" or page.url)
      if url and url ~= "" then open(proto.normalize(url), true) else draw() end
    elseif k == "r" or k == "R" then
      local top, sel = page.top, page.sel
      open(page.url, false)
      page.sel = sel
      scrollTo(top)
      draw()
    elseif k == "u" or k == "U" then up()
    elseif k == "b" then addBookmark() draw()
    elseif k == "B" then open("about:bookmarks", true)
    elseif k == "h" or k == "H" or k == "?" then open("about:help", true)
    elseif (k == "a" or k == "A") and page.warn then
      proto.trust(page.warn.host, page.warn.new)
      open(page.warn.url, false)
    end
  end
end

local saved = term.attr()
term.showcursor(false)
local ok, why = pcall(run)
term.attr(saved)
term.cls()
term.showcursor(true)
if not ok then error(why, 0) end  -- Ctrl+C: the shell prints ^C
