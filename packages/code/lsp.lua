-- code.lsp: what the editor knows about Lua code, without a language
-- server: syntax errors (the compiler's), symbols (functions, locals) of a
-- file and of the whole project, definitions, references and completion.
local host = require "code.host"
local fs = host.fs
local ui = require "code.ui"

local M = {}

local MAX_FILES = 300          -- files indexed in a project
local MAX_INDEX_SIZE = 64 * 1024

local KEYWORDS = {
  "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
  "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}

-- ------------------------------------------------------------------ diagnostics

-- The syntax error of a buffer: {line = {msg = ...}}, empty if none.
function M.check(b)
  if b.lang ~= "lua" then return {} end
  local f, err = load(b:text(), "=" .. b:title(), "t", {})
  if f then return {} end
  local line, msg = tostring(err):match("^[^:]*:(%d+): (.*)$")
  line = tonumber(line) or 1
  -- "near <eof>": the problem is usually an "end" missing higher up
  return {[math.min(line, #b.lines)] = {msg = msg or tostring(err)}}
end

-- ------------------------------------------------------------------ symbols

-- Functions and top-level locals of lines: list of {name, line, kind, depth}
-- (kind "function" or "local"; name may be "a.b:c").
function M.symbols(lines)
  local out = {}
  local depth = 0
  for i, s in ipairs(lines) do
    local code = s:gsub("%-%-.*$", "")
    local ind = #code:match("^ *")
    local name = code:match("^%s*local%s+function%s+([%w_]+)") or code:match("^%s*function%s+([%w_.:]+)")
    if name then
      out[#out + 1] = {name = name, line = i, kind = "function", depth = ind}
    else
      name = code:match("^%s*local%s+([%w_]+)%s*=%s*function") or code:match("^%s*([%w_.]+)%s*=%s*function")
      if name then
        out[#out + 1] = {name = name, line = i, kind = "function", depth = ind}
      elseif ind == 0 then
        local names = code:match("^local%s+([%w_,%s]+)=") or code:match("^local%s+([%w_,%s]+)$")
        if names then
          for n in names:gmatch("[%w_]+") do
            out[#out + 1] = {name = n, line = i, kind = "local", depth = 0}
          end
        end
      end
    end
  end
  return out
end

-- The last part of a symbol name: "draw" for "M.view:draw".
local function short(name)
  return name:match("[%w_]+$") or name
end
M.short = short

-- ------------------------------------------------------------------ project

-- index[path] = {mtime, symbols}
local index = {}
local files  -- the .lua files of the project, once listed

local function walk(dir, out)
  local list = fs.dir(dir) or {}
  for _, e in ipairs(list) do
    if #out >= MAX_FILES then return end
    local p = (dir == "/" and "" or dir) .. "/" .. e.name
    if e.dir then
      if e.name ~= ".git" and e.name ~= ".pkg" then walk(p, out) end
    elseif e.name:match("%.lua$") and (e.size or 0) <= MAX_INDEX_SIZE then
      out[#out + 1] = p
    end
  end
end

-- The .lua files under root (listed once; forget() lists them again).
function M.files(root)
  if not files then
    files = {}
    walk(root, files)
  end
  return files
end

function M.forget()
  files = nil
end

local mtime = fs.mtime

-- The symbols of a file on disk, cached while it does not change.
local function fileSymbols(path)
  local t = mtime(path)
  local e = index[path]
  if e and e.mtime == t then return e.symbols end
  local text = fs.read(path) or ""
  local lines = {}
  for l in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = l end
  local syms = M.symbols(lines)
  index[path] = {mtime = t, symbols = syms}
  return syms
end

-- Where name is defined: a list of {path, line, name}, the open buffers
-- first (bufs: path -> buffer), then the files of the project.
function M.definitions(name, root, bufs)
  local want = short(name)
  local out, seen = {}, {}
  local function add(path, syms)
    for _, s in ipairs(syms) do
      if short(s.name) == want and (s.kind == "function" or s.depth == 0) then
        out[#out + 1] = {path = path, line = s.line, name = s.name}
      end
    end
  end
  for path, b in pairs(bufs) do
    if b.lang == "lua" then
      seen[path] = true
      add(path, M.symbols(b.lines))
    end
  end
  for _, path in ipairs(M.files(root)) do
    if not seen[path] then add(path, fileSymbols(path)) end
  end
  return out
end

-- Lines holding the word, in the open buffers and the project's files:
-- a list of {path, line, col, text}. max: most results (200).
function M.references(word, root, bufs, max)
  max = max or 200
  local pat = "%f[%w_]" .. word:gsub("%p", "%%%0") .. "%f[^%w_]"
  local out, seen = {}, {}
  local function scan(path, lines)
    for i, s in ipairs(lines) do
      if #out >= max then return end
      local a = s:find(pat)
      if a then out[#out + 1] = {path = path, line = i, col = ui.len(s:sub(1, a - 1)), text = s} end
    end
  end
  for path, b in pairs(bufs) do
    seen[path] = true
    scan(path, b.lines)
  end
  for _, path in ipairs(M.files(root)) do
    if #out >= max then break end
    if not seen[path] then
      local lines = {}
      for l in ((fs.read(path) or "") .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = l end
      scan(path, lines)
    end
  end
  return out
end

-- ------------------------------------------------------------------ completion

-- The expression before column c of line s: "termina.term.pu" -> "termina.term", "pu".
function M.prefix(s, c)
  local before = s:sub(1, ui.offset(s, c) - 1)
  local chain, word = before:match("([%w_%.:]*)[%.:]([%w_]*)$")
  if chain then return chain ~= "" and chain or nil, word end
  return nil, before:match("([%w_]*)$") or ""
end

-- The table a dotted name leads to among the live globals, or nil.
local function resolve(chain)
  local t = _G
  for part in chain:gmatch("[^%.:]+") do
    if type(t) ~= "table" then return nil end
    t = rawget(t, part)
  end
  return type(t) == "table" and t or nil
end

-- Names of locals assigned a require: local term = termina.term -> "termina.term".
local function aliases(lines)
  local out = {}
  for _, s in ipairs(lines) do
    local names, values = s:match("^%s*local%s+([%w_,%s]+)=%s*(.-)%s*$")
    if names then
      local ns, vs = {}, {}
      for n in names:gmatch("[%w_]+") do ns[#ns + 1] = n end
      for v in (values .. ","):gmatch("%s*([^,]-)%s*,") do vs[#vs + 1] = v end
      for i, n in ipairs(ns) do
        local v = vs[i]
        if v and v:match("^[%w_.]+$") then out[n] = v end
        local req = v and v:match("^require%s*%(?%s*[\"']([%w_.]+)[\"']")
        if req and package.loaded[req] then out[n] = "package.loaded." .. req end
      end
    end
  end
  return out
end

-- Candidates for completion at the cursor of buffer b: a sorted list of
-- {label, kind}, and the word typed so far.
function M.complete(b)
  local chain, word = M.prefix(b.lines[b.cy], b.cx)
  local found, out = {}, {}
  local function add(name, kind)
    if not found[name] and name:sub(1, #word) == word and name ~= word then
      found[name] = true
      out[#out + 1] = {label = name, kind = kind}
    end
  end
  if chain then
    local al = aliases(b.lines)
    local first, rest = chain:match("^([%w_]+)(.*)$")
    local full = first and al[first] and (al[first] .. rest) or chain
    local t = full:match("^package%.loaded%.") and
        resolve("package.loaded") and package.loaded[full:sub(16)] or resolve(full)
    if t then
      for k, v in pairs(t) do
        if type(k) == "string" then add(k, type(v) == "function" and "function" or type(v)) end
      end
    end
    -- fields used in the file: "chain.name"
    local pat = chain:gsub("%p", "%%%0") .. "[%.:]([%w_]+)"
    for _, s in ipairs(b.lines) do
      for n in s:gmatch(pat) do add(n, "field") end
    end
  else
    if word == "" then return {}, word end
    for _, k in ipairs(KEYWORDS) do add(k, "keyword") end
    for _, s in ipairs(M.symbols(b.lines)) do add(short(s.name), s.kind) end
    for k, v in pairs(_G) do
      if type(k) == "string" then add(k, type(v) == "function" and "function" or "global") end
    end
    for _, s in ipairs(b.lines) do
      for n in s:gmatch("[%a_][%w_]*") do
        if #n > 2 then add(n, "word") end
      end
    end
  end
  table.sort(out, function(x, y) return x.label < y.label end)
  return out, word
end

return M
