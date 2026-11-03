-- netbench: network benchmark. Times TCP connections and small HTTPS
-- requests, then a download and an upload, against speed.cloudflare.com
-- (or downloads a given URL). Nothing is sent but zeros and a user agent.
-- Usage: netbench [-d <KB>] [-u <KB>] [-url <url>]
local term, fs, sys, net, write = termina.term, termina.fs, termina.sys, termina.net, termina.write
local RED, GREEN, YELLOW, CYAN, DIM, NORMAL = 0x0C, 0x0A, 0x0E, 0x0B, 0x08, 0x07

local HOST = "speed.cloudflare.com"
local BASE = "https://" .. HOST
local HEADERS = {["User-Agent"] = "termina-netbench/1.0.1"}
local CONNECTS, REQUESTS = 5, 3
local TMP = "/.netbench.tmp"  -- upload body, streamed from the filesystem

local USAGE = "usage: netbench [-d <KB>] [-u <KB>] [-url <url>]  (-u 0: no upload)"

-- Before TERMINA 2.5.1, an empty answer from a server that closes the
-- connection at once (Cloudflare does) came back as an error although
-- nothing was missing: take it as a 200.
local function request(t)
  local code, err = net.request(t)
  if not code and err and (err:find("^incomplete body %(0/0 bytes%): not connected")
                           or err:find("^incomplete body %(0/%? bytes%): not connected")) then
    return 200
  end
  return code, err
end

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
  return string.format("%.1fM", n / (1024 * 1024))
end

-- "48K/s" for n bytes in ms milliseconds.
local function rate(n, ms)
  local bps = n * 1000 / math.max(ms, 1)
  if bps < 1024 then return string.format("%dB/s", math.floor(bps)) end
  if bps < 10 * 1024 then return string.format("%.1fK/s", bps / 1024) end
  if bps < 1024 * 1024 then return string.format("%dK/s", math.floor(bps / 1024)) end
  return string.format("%.2fM/s", bps / (1024 * 1024))
end

-- "min/avg/max" of a list of milliseconds.
local function stats(list)
  local lo, hi, sum = math.huge, 0, 0
  for _, v in ipairs(list) do
    lo, hi, sum = math.min(lo, v), math.max(hi, v), sum + v
  end
  return lo, sum // #list, hi
end

local function row(test, result, detail)
  say(string.format("  %-14s %-18s %s", test, result, detail or ""))
end

-- ------------------------------------------------------------------ tests

-- The first connection also resolves the name: it is shown apart.
local function connecttest()
  local times, first = {}, nil
  for i = 1, CONNECTS do
    progress(string.format("  TCP connect %d/%d...", i, CONNECTS))
    local t0 = sys.millis()
    local s, err = net.connect(HOST, 443)
    local ms = sys.millis() - t0
    if not s then error(err, 0) end
    s:close()
    if i == 1 then first = ms else times[#times + 1] = ms end
  end
  local lo, avg, hi = stats(times)
  row("TCP connect", string.format("%d/%d/%d ms", lo, avg, hi), string.format("first (DNS) %d ms", first))
end

-- An empty HTTPS GET: TLS handshake and one round trip. Returns the best time.
local function requesttest()
  local times = {}
  for i = 1, REQUESTS do
    progress(string.format("  HTTPS request %d/%d...", i, REQUESTS))
    local t0 = sys.millis()
    local code, err = request{url = BASE .. "/__down?bytes=0", headers = HEADERS}
    if not code then error(err, 0) end
    if code ~= 200 then error("HTTP error " .. code, 0) end
    times[#times + 1] = sys.millis() - t0
  end
  local lo, avg, hi = stats(times)
  row("HTTPS request", string.format("%d/%d/%d ms", lo, avg, hi), "min/avg/max")
  return lo
end

-- The rate is counted from the first byte of the body, so the handshake is
-- left out; the total time includes it.
local function downloadtest(url)
  local t0 = sys.millis()
  local tbody, got = nil, 0
  local code, err = request{url = url, headers = HEADERS, progress = function(n, total)
    local now = sys.millis()
    tbody = tbody or now
    got = n
    progress(string.format("  download %s%s  %s", bytes(n), total and ("/" .. bytes(total)) or "",
                           rate(n, now - tbody)))
  end}
  if not code then error(err, 0) end
  if code ~= 200 then error("HTTP error " .. code, 0) end
  local now = sys.millis()
  row("download", rate(got, now - (tbody or t0)), string.format("%s in %d ms", bytes(got), now - t0))
end

-- No progress while the body goes out: the rate leaves out the best empty
-- request time (handshake and round trip).
local function uploadtest(size, latency)
  progress("  preparing " .. bytes(size) .. "...")
  local f, err = fs.open(TMP, "w")
  if not f then error(err, 0) end
  local chunk = string.rep("\0", 4096)
  local left = size
  while left > 0 do
    local n = math.min(#chunk, left)
    f:write(n == #chunk and chunk or chunk:sub(1, n))
    left = left - n
  end
  f:close()
  chunk = nil
  collectgarbage()
  progress("  upload " .. bytes(size) .. "...")
  local t0 = sys.millis()
  local code
  code, err = request{url = BASE .. "/__up", method = "POST", headers = HEADERS, bodyfile = TMP}
  local ms = sys.millis() - t0
  fs.remove(TMP)
  if not code then error(err, 0) end
  if code ~= 200 then error("HTTP error " .. code, 0) end
  row("upload", rate(size, math.max(ms - latency, 1)), string.format("%s in %d ms", bytes(size), ms))
end

-- ------------------------------------------------------------------ entry point

local down, up, url = 1024 * 1024, 256 * 1024, nil
local i = 1
while arg[i] do
  local a, v = arg[i], arg[i + 1]
  if a == "-d" or a == "-u" then
    local kb = tonumber(v or "")
    if not kb or kb < 0 then return say(USAGE, RED) end
    kb = math.floor(kb) * 1024
    if a == "-d" then down = kb else up = kb end
    i = i + 1
  elseif a == "-url" and v then
    url = v
    i = i + 1
  else
    return print(USAGE)
  end
  i = i + 1
end

if url and not url:match("^https?://") then return say("the address must start with http:// or https://", RED) end
say(url and ("download from " .. url) or (HOST .. " (Cloudflare)"), CYAN)
say(string.format("  %-14s %-18s %s", "test", "result", ""), DIM)

local ok, err = pcall(function()
  if url then return downloadtest(url) end
  connecttest()
  local latency = requesttest()
  if down > 0 then downloadtest(BASE .. "/__down?bytes=" .. down) end
  if up > 0 then uploadtest(up, latency) end
end)
progress("")
fs.remove(TMP)
if not ok then
  if type(err) ~= "string" then error(err, 0) end  -- Ctrl+C: let it through
  return say("  error: " .. err, RED)
end
say("done", GREEN)
