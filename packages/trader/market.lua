-- trader.market: the simulated stock market. Prices are integer cents.
-- A tick moves every stock by a random walk (the whole market, its sector
-- and its own noise) plus the drift of the news in progress; news also
-- makes prices jump at once. The state is plain data, so it can be saved.
local M = {}

M.TICKS = 60          -- ticks in a trading day
M.DAYS = 20           -- trading days in a game
local KEEP = 60       -- daily candles kept per stock
local NEWS_KEEP = 20  -- headlines kept
local MIN, MAX = 50, 999999

M.SECTORS = {"Tech", "Energy", "Pharma", "Retail"}

-- price: at the start of the history; vol: standard deviation of a tick's
-- move, in basis points (1/100 %); beta: how much it follows the market,
-- in tenths.
M.CO = {
  {sym = "BYTE", name = "Bytecraft Systems", sector = 1, price = 4250, vol = 35, beta = 12},
  {sym = "QBIT", name = "Qubit Dynamics", sector = 1, price = 1875, vol = 70, beta = 15},
  {sym = "PTRL", name = "Petrolux Energy", sector = 2, price = 6120, vol = 30, beta = 8},
  {sym = "SOLR", name = "Solaris Grid", sector = 2, price = 2340, vol = 55, beta = 11},
  {sym = "HELX", name = "Helix Pharma", sector = 3, price = 8800, vol = 30, beta = 7},
  {sym = "NOVA", name = "Novagen Bio", sector = 3, price = 1250, vol = 90, beta = 10},
  {sym = "MART", name = "Megamart Stores", sector = 4, price = 3610, vol = 25, beta = 9},
  {sym = "BUZZ", name = "Buzzwear Fashion", sector = 4, price = 980, vol = 60, beta = 13},
}

-- News about one company: text, jump and drift per tick in basis points,
-- ticks the drift lasts, and the only sector it fits (none: any).
local CO_NEWS = {
  {"%s beats earnings estimates", 700, 6, 20},
  {"%s misses earnings and cuts its forecast", -900, -6, 20},
  {"%s announces a share buyback", 400, 4, 15},
  {"%s wins a giant government contract", 600, 5, 20},
  {"%s CEO quits amid an accounting probe", -1200, -8, 25},
  {"%s recalls its flagship product", -700, -5, 20},
  {"Hackers breach the %s customer database", -600, -4, 15},
  {"Star investor takes a 10%% stake in %s", 500, 5, 15},
  {"%s to be bought out at a premium", 1500, 2, 10},
  {"Analysts downgrade %s to sell", -400, -4, 15},
  {"Analysts upgrade %s to buy", 400, 4, 15},
  {"%s unveils a revolutionary chip", 900, 6, 20, 1},
  {"%s data center goes up in flames", -1000, -6, 20, 1},
  {"%s strikes a huge oil field", 900, 5, 20, 2},
  {"Oil spill: %s faces billions in fines", -1100, -6, 25, 2},
  {"FDA approves a blockbuster drug from %s", 1300, 6, 20, 3},
  {"%s drug fails its final trial", -1600, -6, 20, 3},
  {"%s sells out its new collection", 800, 5, 20, 4},
  {"%s store traffic collapses", -800, -5, 20, 4},
}

-- Rumors, good then bad: the news follows, or a denial.
local RUMORS = {
  {"rumor says %s will smash its targets", "insiders whisper %s has a big deal coming"},
  {"rumor says regulators are after %s", "insiders whisper %s is in trouble"},
}

local SECTOR_NEWS = {  -- sector, text, jump, drift, ticks
  {1, "chip shortage hits tech makers", -500, -4, 20},
  {1, "AI frenzy lifts tech stocks", 500, 5, 20},
  {2, "oil price spikes after a pipeline blast", 700, 5, 20},
  {2, "oil glut sends energy stocks lower", -600, -4, 20},
  {3, "regulators approve a wave of new drugs", 600, 4, 20},
  {3, "lawmakers move to cap drug prices", -700, -5, 20},
  {4, "record holiday sales for retailers", 500, 4, 20},
  {4, "consumer confidence plunges", -500, -4, 20},
}

local MARKET_NEWS = {  -- text, jump, drift, ticks
  {"central bank cuts rates, stocks rally", 300, 4, 30},
  {"inflation surprise rattles investors", -400, -4, 30},
  {"trade deal signed, markets cheer", 400, 3, 30},
  {"FLASH CRASH, panic selling everywhere", -1500, -6, 15},
}

local function gauss()  -- about normal, standard deviation 1
  return (math.random() + math.random() + math.random() - 1.5) * 2
end

local function move(s, bps)
  local p = math.floor(s.p * (1 + bps / 10000) + 0.5)
  if p < MIN then p = MIN elseif p > MAX then p = MAX end
  s.p = p
  if p > s.h then s.h = p end
  if p < s.l then s.l = p end
end

local function hits(k, id, i)
  return k == "market" or (k == "sector" and M.CO[i].sector == id) or (k == "co" and i == id)
end

local function drift(m, i)
  local d = 0
  for _, f in ipairs(m.fx) do
    if hits(f.k, f.id, i) then d = d + f.d end
  end
  return d
end

-- The random part of a tick; scale > 1 stands for several ticks at once.
local function moves(m, scale, fx)
  local mk = gauss() * 15 + m.regime
  local sec = {}
  for k = 1, #M.SECTORS do sec[k] = gauss() * 10 end
  for i, co in ipairs(M.CO) do
    local s = m.stocks[i]
    -- a slow pull back to the company's base price, so that none ends up worthless
    local pull = (co.price - s.p) * 3 / co.price
    local bps = (mk * co.beta / 10 + sec[co.sector] + gauss() * co.vol + pull) * scale
    if fx then bps = bps + drift(m, i) end
    move(s, bps)
  end
end

local function apply(m, k, id, gap, d, n)
  for i, co in ipairs(M.CO) do
    if hits(k, id, i) then
      -- the whole market's shocks hit high-beta stocks harder
      move(m.stocks[i], k == "market" and gap * co.beta // 10 or gap)
    end
  end
  if d ~= 0 then m.fx[#m.fx + 1] = {k = k, id = id, d = d, n = n} end
end

function M.clock(m)
  local mn = 570 + m.t * 390 // M.TICKS  -- 9:30 to 16:00
  return string.format("%02d:%02d", mn // 60, mn % 60)
end

-- tone: 1 good news, -1 bad, 0 a rumor; big: worth a fanfare.
local function headline(m, text, tone, big, out)
  local n = {d = m.day, c = M.clock(m), text = text, tone = tone, at = m.total}
  table.insert(m.news, 1, n)
  if #m.news > NEWS_KEEP then table.remove(m.news) end
  out[#out + 1] = {text = text, tone = tone, big = big}
end

local function conews(i, good)  -- a news template for company i (good: nil any)
  local list = {}
  for k, t in ipairs(CO_NEWS) do
    if (not t[5] or t[5] == M.CO[i].sector) and (good == nil or (t[2] > 0) == good) then
      list[#list + 1] = k
    end
  end
  return list[math.random(#list)]
end

local function fire(m, i, k, out)
  local t, co = CO_NEWS[k], M.CO[i]
  apply(m, "co", i, t[2], t[3], t[4])
  headline(m, co.sym .. ": " .. t[1]:format(co.name), t[2] > 0 and 1 or -1, math.abs(t[2]) >= 1000, out)
end

local function events(m, out)
  for j = #m.pending, 1, -1 do  -- rumors that come due
    local r = m.pending[j]
    if m.total >= r.at then
      table.remove(m.pending, j)
      if r.real then
        fire(m, r.i, r.k, out)
      else
        local co = M.CO[r.i]
        apply(m, "co", r.i, r.good and -300 or 300, 0, 0)
        headline(m, co.sym .. ": " .. co.name .. " denies the rumors", r.good and -1 or 1, false, out)
      end
    end
  end
  if math.random(40) ~= 1 then return end
  local r = math.random(100)
  if r <= 60 then
    local i = math.random(#M.CO)
    local co = M.CO[i]
    if math.random(3) == 1 then
      local good = math.random(2) == 1
      m.pending[#m.pending + 1] = {at = m.total + math.random(6, 20), i = i, k = conews(i, good),
                                   good = good, real = math.random(10) <= 7}
      apply(m, "co", i, good and 150 or -150, 0, 0)
      local t = RUMORS[good and 1 or 2]
      headline(m, co.sym .. ": " .. t[math.random(#t)]:format(co.name), 0, false, out)
    else
      fire(m, i, conews(i), out)
    end
  elseif r <= 85 then
    local t = SECTOR_NEWS[math.random(#SECTOR_NEWS)]
    apply(m, "sector", t[1], t[3], t[4], t[5])
    headline(m, M.SECTORS[t[1]]:upper() .. ": " .. t[2], t[3] > 0 and 1 or -1, false, out)
  else
    local t = MARKET_NEWS[math.random(#MARKET_NEWS)]
    apply(m, "market", 0, t[2], t[3], t[4])
    headline(m, "MARKET: " .. t[1], t[2] > 0 and 1 or -1, math.abs(t[2]) >= 1000, out)
  end
end

-- One tick of the trading day → the headlines it brought.
function M.tick(m)
  local out = {}
  m.t = m.t + 1
  m.total = m.total + 1
  for _, s in ipairs(m.stocks) do s.last = s.p end
  events(m, out)
  moves(m, 1, true)
  for j = #m.fx, 1, -1 do
    local f = m.fx[j]
    f.n = f.n - 1
    if f.n <= 0 then table.remove(m.fx, j) end
  end
  for _, s in ipairs(m.stocks) do s.ticks[#s.ticks + 1] = s.p end
  return out
end

-- The closing bell: today becomes a daily candle.
function M.close(m)
  for _, s in ipairs(m.stocks) do
    local d = s.days
    d[#d + 1] = {s.o, s.h, s.l, s.p}
    if #d > KEEP then table.remove(d, 1) end
    s.prev = s.p
  end
  m.day = m.day + 1
end

-- The next morning: overnight gaps and a new mood for the market.
function M.open(m)
  m.t = 0
  m.regime = (math.random(7) - 3.5) * 0.5  -- in bps per tick, a little more often up
  for i, s in ipairs(m.stocks) do
    move(s, gauss() * M.CO[i].vol)
    s.o, s.h, s.l, s.last = s.p, s.p, s.p, s.p
    s.ticks = {s.p}
  end
end

-- The market index: 1000 at the start of the history → now, last close.
function M.index(m)
  local now, prev = 0, 0
  for _, s in ipairs(m.stocks) do now, prev = now + s.p, prev + s.prev end
  return now / m.base * 1000, prev / m.base * 1000
end

function M.new()
  local m = {day = 1, t = 0, total = 0, regime = 0, base = 0, fx = {}, pending = {}, news = {}, stocks = {}}
  for i, co in ipairs(M.CO) do
    local p = co.price
    m.stocks[i] = {p = p, o = p, h = p, l = p, prev = p, last = p, days = {}, ticks = {p}}
    m.base = m.base + p
  end
  for _ = 1, 30 do  -- a month of history, so that the charts start full
    for _ = 1, 12 do moves(m, 2.2, false) end
    M.close(m)
    M.open(m)
  end
  m.day = 1
  return m
end

return M
