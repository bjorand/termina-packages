-- fortune: prints a random saying.
--   fortune            one from the package's fortunes.txt and /etc/fortunes
--   fortune -f <file>  one from that file only
-- The files hold the sayings separated by lines with only "%" on them, as the
-- classic Unix fortune files do. TERMINA shows one at boot, under /etc/motd;
-- "pkg remove fortune" turns that off.
local sys = termina.sys

local SOURCES = { "/pkg/fortune/fortunes.txt", "/etc/fortunes" }

-- Adds the sayings of a file to list; false if the file cannot be read.
local function load(path, list)
  local f = io.open(path, "r")
  if not f then return false end
  local text = f:read("a"):gsub("\r", "")
  f:close()
  local entry = {}
  local function flush()
    local s = table.concat(entry, "\n"):match("^%s*(.-)%s*$")
    if s ~= "" then list[#list + 1] = s end
    entry = {}
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line == "%" then flush() else entry[#entry + 1] = line end
  end
  flush()
  return true
end

local function main()
  local list = {}
  if arg[1] == "-f" and arg[2] and not arg[3] then
    if not load(arg[2], list) then return print("fortune: cannot read " .. arg[2]) end
  elseif arg[1] then
    return print("usage: fortune [-f file]")
  else
    for _, path in ipairs(SOURCES) do load(path, list) end
  end
  if #list == 0 then return print("fortune: no sayings found") end
  print(list[sys.random(#list)])
end

main()
