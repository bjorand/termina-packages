-- iobench: storage benchmark. Writes then reads a test file with several
-- block sizes, does random 4 KB reads and creates small files, on / and on
-- /mnt/sd when the card is mounted (or on the directories given).
-- Usage: iobench [-s <KB>] [dir...]
local term, fs, sys, write = termina.term, termina.fs, termina.sys, termina.write
local RED, GREEN, YELLOW, CYAN, DIM, NORMAL = 0x0C, 0x0A, 0x0E, 0x0B, 0x08, 0x07

local BLOCKS = {512, 4096, 16384}
local RANDOM_READS = 64
local SMALL_FILES, SMALL_SIZE = 32, 128
local MARGIN = 32 * 1024  -- left free on the filesystem

local USAGE = "usage: iobench [-s <KB>] [dir...]"

local function say(text, attr)
  if attr then term.attr(attr) end
  print(text)
  if attr then term.attr(NORMAL) end
end

local function progress(text)
  local w = term.cols() - 1
  if #text > w then text = text:sub(1, w) end
  write("\r" .. text .. string.rep(" ", w - #text) .. "\r")
end

local function bytes(n)
  if n < 1024 then return n .. "B" end
  if n < 1024 * 1024 then return string.format("%dK", (n + 1023) // 1024) end
  if n < 1024 * 1024 * 1024 then return string.format("%.1fM", n / (1024 * 1024)) end
  return string.format("%.1fG", n / (1024 * 1024 * 1024))
end

-- "48K/s" for n bytes in ms milliseconds.
local function rate(n, ms)
  local bps = n * 1000 / math.max(ms, 1)
  if bps < 1024 then return string.format("%dB/s", math.floor(bps)) end
  if bps < 10 * 1024 then return string.format("%.1fK/s", bps / 1024) end
  if bps < 1024 * 1024 then return string.format("%dK/s", math.floor(bps / 1024)) end
  return string.format("%.2fM/s", bps / (1024 * 1024))
end

local function per(count, ms, unit)
  return string.format("%d %s/s", math.floor(count * 1000 / math.max(ms, 1)), unit)
end

local function row(test, block, result, ms)
  say(string.format("  %-12s %-6s %-12s %s", test, block, result, string.format("%dms", ms)))
end

local function join(dir, name)
  if dir:sub(-1) == "/" then return dir .. name end
  return dir .. "/" .. name
end

local function open(path, mode)
  local f, err = fs.open(path, mode)
  if not f then error(err, 0) end
  return f
end

-- ------------------------------------------------------------------ tests

local function writetest(file, size, block)
  local chunk = string.rep("x", block)
  local t0 = sys.millis()
  local f = open(file, "w")
  local left = size
  while left > 0 do
    local n = math.min(block, left)
    f:write(n == block and chunk or chunk:sub(1, n))
    left = left - n
  end
  f:close()
  return sys.millis() - t0
end

local function readtest(file, block)
  local t0, got = sys.millis(), 0
  local f = open(file, "r")
  while true do
    local s = f:read(block)
    if not s then break end
    got = got + #s
  end
  f:close()
  return sys.millis() - t0, got
end

local function randomtest(file, size)
  local block = 4096
  local slots = math.max(size // block, 1)
  local seed = 12345  -- small LCG: numbers are 32 bits on the machine
  local t0 = sys.millis()
  local f = open(file, "r")
  for _ = 1, RANDOM_READS do
    seed = (seed * 75 + 74) % 65537
    f:seek((seed % slots) * block)
    f:read(block)
  end
  f:close()
  return sys.millis() - t0
end

local function smallname(dir, i) return join(dir, ".iob" .. i) end

local function smalltest(dir)
  local data = string.rep("s", SMALL_SIZE)
  local t0 = sys.millis()
  for i = 1, SMALL_FILES do
    local f = open(smallname(dir, i), "w")
    f:write(data)
    f:close()
  end
  local tw = sys.millis() - t0
  t0 = sys.millis()
  for i = 1, SMALL_FILES do fs.remove(smallname(dir, i)) end
  return tw, sys.millis() - t0
end

local function cleanup(dir)
  fs.remove(join(dir, ".iobench.tmp"))
  for i = 1, SMALL_FILES do
    local p = smallname(dir, i)
    if fs.exists(p) then fs.remove(p) end
  end
end

-- ------------------------------------------------------------------ targets

local function bench(dir, want)
  if not fs.isdir(dir) then
    say(dir .. ": not a directory", RED)
    return
  end
  local total, used = fs.info(dir)
  local free = total - used
  say(string.format("%s  (%s free of %s)", dir, bytes(free), bytes(total)), CYAN)
  -- fs.info gives floats past 2 GB (SD cards): back to an integer here.
  local size = math.tointeger(math.floor(math.min(want, free - MARGIN)))
  size = size - size % 4096
  if size < 16384 then
    say("  not enough free space, skipped", YELLOW)
    return
  end
  if size < want then say("  test file reduced to " .. bytes(size), YELLOW) end
  local file = join(dir, ".iobench.tmp")
  say(string.format("  %-12s %-6s %-12s %s", "test", "block", "speed", "time"), DIM)
  for _, block in ipairs(BLOCKS) do
    progress("  write " .. bytes(size) .. " in " .. bytes(block) .. " blocks...")
    local ms = writetest(file, size, block)
    row("write", bytes(block), rate(size, ms), ms)
    collectgarbage()
  end
  for _, block in ipairs(BLOCKS) do
    progress("  read " .. bytes(size) .. " in " .. bytes(block) .. " blocks...")
    local ms, got = readtest(file, block)
    if got ~= size then error(string.format("read %d bytes, expected %d", got, size), 0) end
    row("read", bytes(block), rate(size, ms), ms)
    collectgarbage()
  end
  progress("  random reads...")
  local ms = randomtest(file, size)
  row("random read", "4K", per(RANDOM_READS, ms, "op"), ms)
  fs.remove(file)
  progress("  small files...")
  local tw, tr = smalltest(dir)
  row("create", bytes(SMALL_SIZE), per(SMALL_FILES, tw, "file"), tw)
  row("delete", "", per(SMALL_FILES, tr, "file"), tr)
end

-- ------------------------------------------------------------------ entry point

local size, dirs = 256 * 1024, {}
local i = 1
while arg[i] do
  local a = arg[i]
  if a == "-s" then
    local kb = tonumber(arg[i + 1] or "")
    if not kb or kb < 16 then return say(USAGE .. " (size: 16 KB minimum)", RED) end
    size = math.floor(kb) * 1024
    i = i + 1
  elseif a == "-h" or a == "--help" then
    return print(USAGE)
  else
    dirs[#dirs + 1] = a
  end
  i = i + 1
end
if #dirs == 0 then
  dirs[1] = "/"
  if fs.isdir("/mnt/sd") then
    local total = fs.info("/mnt/sd")
    if total and total > 0 then dirs[2] = "/mnt/sd" end
  end
end

for _, dir in ipairs(dirs) do
  local ok, err = pcall(bench, dir, size)
  progress("")
  cleanup(dir)
  if not ok then
    if type(err) ~= "string" then error(err, 0) end  -- Ctrl+C: let it through
    say("  error: " .. err, RED)
  end
end
say("done", GREEN)
