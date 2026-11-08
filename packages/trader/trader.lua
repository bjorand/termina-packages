-- trader: a real-time stock market game. Prices move every half second and
-- the news moves them more; buy, sell short, borrow up to twice your net
-- worth, and end 20 trading days as rich as you can without a margin call.
--   trader     title screen: new game, continue, high scores, how to play
-- Keys in a game: Up/Down (or 1-8) pick a stock, B buy, S sell or short,
-- C close the position, +/- lot size, Tab daily or intraday chart,
-- P pause, H help, Q or Esc save and leave. The game is saved at every
-- closing bell too.
if not termina then
  print("trader needs TERMINA 4.0.0 or later")
  return
end
local term, key, sys, sound = termina.term, termina.key, termina.sys, termina.sound
local market = require "trader.market"
local book = require "trader.book"
local save = require "trader.save"

local COLS, ROWS = term.cols(), term.rows()
if COLS < 80 or ROWS < 30 then
  print("trader needs a screen of 80x30 or more")
  return
end

local TICK_MS = 500
local LOTS = {1, 10, 100, 1000, 0}    -- 0: the most the account allows
local N = #market.CO
local WIDE = COLS >= 100
local LW = WIDE and 44 or 33          -- width of the left column
local NEWS_N = ROWS >= 40 and 8 or 6  -- lines of news
local TOPB = ROWS - 5 - NEWS_N        -- last row of the stocks and the chart

local TEXT, DIM, BRIGHT, SEL, CYAN = 0x07, 0x08, 0x0F, 0x70, 0x0B
local UP, DOWN, GOLD, BAR, ALERT = 0x0A, 0x0C, 0x0E, 0x1F, 0x4F
local BOX, BOXHI, BOXUP, BOXDOWN = 0x1F, 0x1E, 0x1A, 0x1C

-- ---------------------------------------------------------------- formatting

local function group(n)  -- 1234567 → "1,234,567"
  local s = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (s:gsub("^,", ""))
end

local function money(c, plus)  -- cents → "$1,234.56"
  local neg = c < 0
  if neg then c = -c end
  local s = string.format("$%s.%02d", group(c // 100), c % 100)
  return (neg and "-" or plus and "+" or "") .. s
end

local function short(c, plus)  -- cents, in 9 characters or so
  local a = c < 0 and -c or c
  local s
  if a >= 100000000 then s = string.format("$%.2fM", a / 100000000)
  elseif a >= 1000000 then s = string.format("$%.1fk", a / 100000)
  else s = money(a) end
  return (c < 0 and "-" or plus and c > 0 and "+" or "") .. s
end

local function qty(n)
  local a = n < 0 and -n or n
  local s = a >= 1000000 and (a // 1000000) .. "M" or a >= 100000 and (a // 1000) .. "k" or tostring(a)
  return (n < 0 and "-" or "") .. s
end

local function pct(a, b) return string.format("%+.1f%%", (a - b) * 100 / b) end

local function len(s) return utf8.len(s) or #s end

local function cut(s, n)
  if n <= 0 then return "" end
  if len(s) <= n then return s end
  return s:sub(1, (utf8.offset(s, n + 1) or #s + 1) - 1)
end

local function put(x, y, s, a, w)  -- → the column after the text
  if w then s = cut(s, w) end
  return x + term.put(x, y, s, a)
end

local function rput(x, y, s, a)  -- right-aligned, ending at column x
  term.put(x - len(s) + 1, y, s, a)
end

local function anykey()
  while true do
    local e = key.wait()
    if e.type == "key" or e.type == "char" or (e.type == "mouse" and e.down) then return e end
  end
end

-- A framed box in the middle of the screen; lines are text or {text, attr}.
local function box(title, lines)
  local w = len(title) + 6
  for _, l in ipairs(lines) do w = math.max(w, len(type(l) == "table" and l[1] or l) + 4) end
  w = math.min(w, COLS - 2)
  local h = #lines + 4
  local x, y = (COLS - w) // 2, (ROWS - h) // 2 + 1
  for r = 0, h - 1 do
    local yy, edge = y + r, r == 0 or r == h - 1
    term.put(x, yy, string.rep(edge and "\u{2550}" or " ", w), BOX)
    term.cell(x, yy, r == 0 and 0xC9 or r == h - 1 and 0xC8 or 0xBA, BOX)
    term.cell(x + w - 1, yy, r == 0 and 0xBB or r == h - 1 and 0xBC or 0xBA, BOX)
  end
  put(x + (w - len(title) - 2) // 2, y, " " .. title .. " ", BOXHI)
  for k, l in ipairs(lines) do
    local t, a = l, BOX
    if type(l) == "table" then t, a = l[1], l[2] end
    put(x + 2, y + 1 + k, t, a, w - 4)
  end
end

local HELP = {
  "Prices move every half second. A day lasts 30 seconds,",
  "a game 20 days. You start with $10,000.",
  "",
  {"B buys and S sells the lot (+/- to change it; MAX is all", BOXHI},
  {"you can). Selling what you don't own is a short sale:", BOXHI},
  {"it makes money when the price falls. C closes a position.", BOXHI},
  "",
  "You may hold up to 2x your net worth. Each order costs $5.",
  "Overnight, borrowed cash costs 0.08% and shorts 0.05%.",
  {"Margin call: when net worth falls under 30% of what you", BOXDOWN},
  {"hold, your biggest positions are sold at once.", BOXDOWN},
  "",
  "Watch the news. Rumors are often true, not always.",
  "Score: your net worth after the closing bell of day 20.",
  "",
  "Up/Down or 1-8 stock, Tab chart, P pause, Q save and quit",
}

-- ------------------------------------------------------------- game screen

local function titlebar(G)
  local m = G.m
  term.fill(1, " ", BAR)
  local x = put(1, 1, "TRADER", BAR | 0x0E)
  x = put(x + 2, 1, string.format("Day %d/%d  %s ", math.min(m.day, market.DAYS), market.DAYS, market.clock(m)), BAR)
  local bw = WIDE and 30 or 14
  local done = m.t * bw // market.TICKS
  x = put(x, 1, string.rep("\u{2588}", done) .. string.rep("\u{2591}", bw - done), BAR)
  local now, prev = market.index(m)
  put(x + 2, 1, string.format("T80 %.1f ", now), BAR)
  put(x + 2 + #string.format("T80 %.1f ", now), 1, string.format("%+.1f%%", (now - prev) * 100 / prev),
      (BAR & 0xF0) | (now >= prev and 0x0A or 0x0C))
  if G.paused then rput(COLS - 2, 1, "PAUSED", BAR | 0x0E) end
end

local function stockrow(G, i, y)
  local co, s, sel = market.CO[i], G.m.stocks[i], i == G.sel
  local bg = sel and SEL or TEXT
  local function fg(c) return sel and (0x70 | (c & 0x07)) or c end
  term.put(0, y, string.rep(" ", LW), bg)
  put(0, y, sel and "\u{25BA}" or " ", sel and 0x70 or DIM)
  put(1, y, co.sym, sel and 0x70 or BRIGHT)
  local pa = s.p > s.last and fg(UP) or s.p < s.last and fg(DOWN) or bg
  rput(14, y, money(s.p), pa)
  rput(22, y, pct(s.p, s.prev), fg(s.p >= s.prev and UP or DOWN))
  local q = G.b.pos[i]
  if q ~= 0 then
    rput(31, y, qty(q), fg(q > 0 and CYAN or GOLD))
    if WIDE then
      local u = (s.p - G.b.cost[i]) * q
      rput(42, y, short(u, true), fg(u >= 0 and UP or DOWN))
    end
  else
    rput(31, y, "-", sel and 0x70 or DIM)
  end
end

local function detail(G)
  local i, co, s = G.sel, market.CO[G.sel], G.m.stocks[G.sel]
  local w = LW - 2
  local x = put(1, 12, co.name, BRIGHT, w)
  put(x + 1, 12, market.SECTORS[co.sector], DIM, LW - x - 2)
  local vol = co.vol < 40 and "low" or co.vol < 65 and "medium" or "high"
  put(1, 13, string.format("Volatility %s, beta %.1f", vol, co.beta / 10), TEXT, w)
  local q = G.b.pos[i]
  if q == 0 then
    put(1, 14, "No position", DIM)
  else
    put(1, 14, string.format("%s %s @ %s", q > 0 and "Long" or "Short", qty(math.abs(q)), money(G.b.cost[i])),
        q > 0 and CYAN or GOLD, w)
    local u = (s.p - G.b.cost[i]) * q
    put(1, 15, "P&L " .. money(u, true) .. "  " .. pct(s.p, G.b.cost[i]), u >= 0 and UP or DOWN, w)
  end
  local lot = LOTS[G.lot] == 0 and "MAX" or qty(LOTS[G.lot])
  x = put(1, 16, "Lot", TEXT)
  x = put(x + 1, 16, " " .. lot .. " ", SEL)
  put(x + 1, 16, string.format("max B %s S %s", qty(book.max(G.b, G.m, i, 1)), qty(book.max(G.b, G.m, i, -1))),
      DIM, LW - x - 2)
end

local function positions(G)
  if TOPB < 19 then return end
  local y = 18
  put(1, y, "Positions", CYAN)
  for i, q in ipairs(G.b.pos) do
    if q ~= 0 and y < TOPB then
      y = y + 1
      local s = G.m.stocks[i]
      local u = (s.p - G.b.cost[i]) * q
      put(1, y, market.CO[i].sym, TEXT)
      rput(12, y, qty(q), q > 0 and CYAN or GOLD)
      rput(24, y, short(u, true), u >= 0 and UP or DOWN)
    end
  end
  if y == 18 then put(11, y, "none", DIM) end
end

-- Candles of the selected stock: the last days, or today by groups of ticks.
local function chart(G)
  local x0, w = LW + 2, COLS - LW - 3
  local i, s, co = G.sel, G.m.stocks[G.sel], market.CO[G.sel]
  local daily = G.chart == "day"
  local pw = w - 10  -- candle columns; the price scale takes the rest
  local cs = {}
  if daily then
    local n = #s.days
    for k = math.max(1, n - pw + 2), n do cs[#cs + 1] = s.days[k] end
    cs[#cs + 1] = {s.o, s.h, s.l, s.p}
  else
    local t = s.ticks
    local per = (market.TICKS + pw) // pw
    local prev = t[1]
    for j = 1, #t, per do
      local o, h, l, c = prev, prev, prev, prev
      for k = j, math.min(j + per - 1, #t) do
        local p = t[k]
        if p > h then h = p end
        if p < l then l = p end
        c = p
      end
      cs[#cs + 1] = {o, h, l, c}
      prev = c
    end
  end
  local x = put(x0, 2, co.sym, BRIGHT)
  put(x + 1, 2, daily and "daily, last " .. #cs .. " days (Tab: today)" or "today (Tab: daily)", DIM, x0 + w - x - 1)
  local lo, hi = math.maxinteger, 0
  for _, c in ipairs(cs) do
    if c[2] > hi then hi = c[2] end
    if c[3] < lo then lo = c[3] end
  end
  local cost = G.b.cost[i]
  if G.b.pos[i] ~= 0 then
    if cost > hi then hi = cost end
    if cost < lo then lo = cost end
  end
  if hi - lo < 8 then hi, lo = hi + 4, lo - 4 end
  local top, h = 3, TOPB - 2
  local function row(p) return top + (hi - p) * (h - 1) // (hi - lo) end
  local sx = x0 + pw + 1
  if G.b.pos[i] ~= 0 then
    local y = row(cost)
    for xx = x0, x0 + pw - 1 do term.cell(xx, y, 0xFA, GOLD) end
    put(sx, y, "cost", GOLD)
  end
  for k, c in ipairs(cs) do
    local xx, a = x0 + k - 1, c[4] >= c[1] and UP or DOWN
    for y = row(c[2]), row(c[3]) do term.cell(xx, y, 0xB3, a) end
    local yt, yb = row(math.max(c[1], c[4])), row(math.min(c[1], c[4]))
    if yt == yb and c[1] == c[4] then
      term.cell(xx, yt, 0xC4, a)
    else
      for y = yt, yb do term.cell(xx, y, 0xDB, a) end
    end
  end
  put(sx, top, money(hi), DIM)
  put(sx, top + (h - 1) // 2, money((hi + lo) // 2), DIM)
  put(sx, top + h - 1, money(lo), DIM)
  put(sx - 1, row(s.p), "\u{25C4}" .. money(s.p), s.p >= s.prev and 0x2F or 0x4F)
end

local function news(G)
  local y0 = TOPB + 1
  term.fill(y0, 0xC4, DIM)
  put(2, y0, " NEWS ", CYAN)
  for k = 1, NEWS_N do
    local n = G.m.news[k]
    if n then
      local y = y0 + k
      if G.m.total - n.at < 6 then put(0, y, "\u{25BA}", GOLD) end
      local x = put(1, y, string.format("D%-2d %s ", n.d, n.c), DIM)
      put(x, y, n.text, n.tone > 0 and UP or n.tone < 0 and DOWN or GOLD, COLS - x - 1)
    end
  end
end

local function portfolio(G)
  local y = ROWS - 3
  local eq = book.value(G.b, G.m)
  local lvl = book.level(G.b, G.m)
  local a = lvl and lvl < book.WARN and G.blink and ALERT or BAR
  term.fill(y, " ", a)
  local sep = " \u{2502} "
  local s = " Net worth " .. money(eq) .. " " .. pct(eq, book.START) .. sep .. "Cash " .. short(G.b.cash) ..
            sep .. (WIDE and "Buying power " or "Power ") .. short(math.max(0, book.power(G.b, G.m))) ..
            sep .. "Margin " .. (lvl and math.min(lvl, 999) .. "%" or "-")
  put(0, y, s, a, COLS - 1)
end

local KEYS = {{"\u{2191}\u{2193}", "Pick"}, {"B", "Buy"}, {"S", "Sell"}, {"C", "Close"}, {"+-", "Lot"},
              {"Tab", "Chart"}, {"P", "Pause"}, {"H", "Help"}, {"Q", "Quit"}}

local function draw(G)
  for y = 1, ROWS - 1 do term.fill(y, " ", TEXT) end
  titlebar(G)
  put(1, 2, "SYM", DIM)
  rput(14, 2, "PRICE", DIM)
  rput(22, 2, "DAY", DIM)
  rput(31, 2, "POS", DIM)
  if WIDE then rput(42, 2, "P&L", DIM) end
  for i = 1, N do stockrow(G, i, 2 + i) end
  detail(G)
  positions(G)
  for y = 2, TOPB do term.cell(LW, y, 0xB3, DIM) end
  chart(G)
  news(G)
  portfolio(G)
  put(1, ROWS - 2, G.msg or "", G.msgA or TEXT, COLS - 2)
  local x = 1
  for _, k in ipairs(KEYS) do
    x = put(x, ROWS - 1, k[1], BRIGHT)
    x = put(x + 1, ROWS - 1, k[2], DIM) + 2
  end
  if G.paused then box("PAUSED", {"P or Space to go on"}) end
end

-- ------------------------------------------------------------------ actions

local function say(G, s, a) G.msg, G.msgA = s, a or TEXT end

local function order(G, dir)
  local i, co = G.sel, market.CO[G.sel]
  local mx = book.max(G.b, G.m, i, dir)
  local want = LOTS[G.lot]
  local q = (want == 0 or want > mx) and mx or want
  if q <= 0 then
    say(G, "Not enough buying power", DOWN)
    sound.tone(220, 80)
    return
  end
  local old, p = G.b.pos[i], G.m.stocks[i].p
  local pnl = book.trade(G.b, G.m, i, q * dir)
  local verb
  if dir > 0 then
    verb = old >= 0 and "Bought" or old + q <= 0 and "Covered" or "Covered and bought"
  else
    verb = old <= 0 and "Shorted" or old - q >= 0 and "Sold" or "Sold and shorted"
  end
  local s = string.format("%s %s %s @ %s", verb, qty(q), co.sym, money(p))
  if want ~= 0 and q < want then s = s .. " (all you could)" end
  if pnl ~= 0 then s = s .. ", P&L " .. money(pnl, true) end
  say(G, s, pnl > 0 and UP or pnl < 0 and DOWN or BRIGHT)
  sound.tone(dir > 0 and 880 or 660, 25)
end

local function closepos(G)
  local i, co = G.sel, market.CO[G.sel]
  local q = G.b.pos[i]
  if q == 0 then return say(G, "No " .. co.sym .. " position to close", DIM) end
  local p = G.m.stocks[i].p
  local pnl = book.trade(G.b, G.m, i, -q)
  say(G, string.format("Closed %s %s @ %s, P&L %s", qty(math.abs(q)), co.sym, money(p), money(pnl, true)),
      pnl >= 0 and UP or DOWN)
  sound.tone(770, 25)
end

local function store(G)
  save.store({m = G.m, b = G.b, sel = G.sel, lot = G.lot, chart = G.chart, dayStart = G.dayStart})
end

-- One tick → "bankrupt" when the net worth is gone.
local function step(G)
  for _, n in ipairs(market.tick(G.m)) do
    if n.big then
      sound.play(n.tone > 0 and "up:d=16,o=6,b=180:c,e,g,c7" or "down:d=8,o=4,b=160:g,e,c")
    else
      sound.tone(n.tone >= 0 and 1200 or 300, 40)
    end
  end
  local sold = book.liquidate(G.b, G.m)
  if #sold > 0 then
    local t = {}
    for _, s in ipairs(sold) do t[#t + 1] = qty(s.q) .. " " .. market.CO[s.i].sym end
    say(G, "MARGIN CALL! Sold " .. table.concat(t, ", "), ALERT)
    sound.play("call:d=8,o=5,b=200:c,p,c,p,c")
  end
  G.blink = not G.blink
  if book.value(G.b, G.m) <= 0 then return "bankrupt" end
end

-- The closing bell → "end" after the last day.
local function dayend(G)
  local m, b = G.m, G.b
  local best, worst
  for i, s in ipairs(m.stocks) do
    local c = (s.p - s.prev) * 1000 // s.prev
    if not best or c > best[2] then best = {i, c} end
    if not worst or c < worst[2] then worst = {i, c} end
  end
  local fee = book.night(b, m)
  local eq = book.value(b, m)
  local day, last = m.day, m.day >= market.DAYS
  draw(G)
  local dp = eq + fee - G.dayStart
  box(string.format("DAY %d CLOSED", day), {
    {"Day P&L      " .. money(dp, true), dp >= 0 and BOXUP or BOXDOWN},
    "Interest     " .. money(-fee),
    {"Net worth    " .. money(eq) .. "  " .. pct(eq, book.START), BOXHI},
    "",
    {string.format("Top gainer   %s %+.1f%%", market.CO[best[1]].sym, best[2] / 10), BOXUP},
    {string.format("Top loser    %s %+.1f%%", market.CO[worst[1]].sym, worst[2] / 10), BOXDOWN},
    "",
    last and "Any key: the final results" or string.format("Any key: day %d", day + 1),
  })
  sound.play("bell:d=4,o=6,b=120:c,8p,c")
  anykey()
  market.close(m)
  if last then return "end" end
  market.open(m)
  G.dayStart = eq
  store(G)
  say(G, string.format("Day %d: the market is open.", m.day), CYAN)
end

local function help()
  box("HOW TO PLAY", HELP)
  anykey()
end

-- → "end", "bankrupt" or "quit" (saved)
local function play(G)
  sys.saver(false)
  local last, dirty = sys.millis(), true
  G.paused = false
  while true do
    for e in key.poll do
      local k = e.type == "key" and e.key or e.type == "char" and e.ch:lower()
      if k == "up" then G.sel = (G.sel - 2) % N + 1
      elseif k == "down" then G.sel = G.sel % N + 1
      elseif k and k:match("^[1-8]$") and tonumber(k) <= N then G.sel = tonumber(k)
      elseif G.paused and k and k ~= "q" and k ~= "esc" then G.paused = false
      elseif k == "b" then order(G, 1)
      elseif k == "s" then order(G, -1)
      elseif k == "c" then closepos(G)
      elseif k == "+" or k == "=" or k == "right" then G.lot = math.min(#LOTS, G.lot + 1)
      elseif k == "-" or k == "left" then G.lot = math.max(1, G.lot - 1)
      elseif k == "tab" then G.chart = G.chart == "day" and "today" or "day"
      elseif k == "p" or k == " " or k == "space" then G.paused = true
      elseif k == "h" or k == "f1" then
        draw(G)
        help()
        last = sys.millis()
      elseif k == "q" or k == "esc" then
        store(G)
        sys.saver(true)
        return "quit"
      elseif e.type == "mouse" and e.down and e.x < LW and e.y >= 3 and e.y < 3 + N then
        G.sel = e.y - 2
      end
      dirty = true
    end
    if not G.paused and sys.millis() - last >= TICK_MS then
      last = last + TICK_MS
      if sys.millis() - last > TICK_MS then last = sys.millis() end  -- no catching up after a stall
      if step(G) == "bankrupt" then
        sys.saver(true)
        return "bankrupt"
      end
      if G.m.t >= market.TICKS then
        if dayend(G) == "end" then
          sys.saver(true)
          return "end"
        end
        last = sys.millis()
      end
      dirty = true
    end
    if dirty then
      draw(G)
      dirty = false
    end
    sys.yield()
  end
end

-- --------------------------------------------------------------- the menus

local function initials(score)
  local name = ""
  while true do
    box("NEW HIGH SCORE", {
      {"Net worth " .. money(score), BOXHI}, "",
      "Your initials: " .. name .. string.rep("_", 3 - #name), "",
      "Enter to confirm",
    })
    local e = anykey()
    if e.type == "char" and #name < 3 and e.ch:match("^%w$") then
      name = name .. e.ch:upper()
    elseif e.type == "key" and e.key == "backspace" then
      name = name:sub(1, -2)
    elseif e.type == "key" and (e.key == "enter" or e.key == "esc") then
      return name ~= "" and name or "???"
    end
  end
end

local function scores(hl)
  local list = save.scores()
  local lines = {}
  if #list == 0 then lines[1] = "No scores yet: play a game!" end
  for k, s in ipairs(list) do
    lines[#lines + 1] = {string.format("%2d. %-3s %15s %8s", k, s.n, money(s.s), pct(s.s, book.START)),
                         k == hl and BOXHI or BOX}
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Any key to go back"
  box("HIGH SCORES", lines)
  anykey()
end

local function gameover(G, bankrupt)
  local b, m = G.b, G.m
  if not bankrupt then book.closeall(b, m) end
  save.drop()
  local eq = book.value(b, m)
  draw(G)
  box(bankrupt and "BANKRUPT" or "FINAL BELL", {
    {"Net worth    " .. money(eq) .. "  " .. pct(eq, book.START), eq >= book.START and BOXUP or BOXDOWN},
    "",
    string.format("Orders       %d (fees %s)", b.trades, money(b.fees)),
    "Interest     " .. money(b.interest),
    {"Best trade   " .. money(b.best, true), BOXUP},
    {"Worst trade  " .. money(b.worst, true), BOXDOWN},
    "Margin calls " .. b.calls,
    "",
    bankrupt and "Your broker closed the account." or "All positions closed at the last prices.",
  })
  sound.play(bankrupt and "lost:d=8,o=5,b=140:g,f#,f,2e" or "won:d=8,o=6,b=160:c,e,g,2c7")
  anykey()
  if not bankrupt and save.qualifies(eq) then
    local rank = save.add(initials(eq), eq)
    draw(G)
    scores(rank)
  end
end

local LETTERS = {
  T = {"#####", "  #  ", "  #  ", "  #  ", "  #  "},
  R = {"#### ", "#   #", "#### ", "#  # ", "#   #"},
  A = {" ### ", "#   #", "#####", "#   #", "#   #"},
  D = {"#### ", "#   #", "#   #", "#   #", "#### "},
  E = {"#####", "#    ", "#### ", "#    ", "#####"},
}

local function drawtitle(g)
  for y = 1, ROWS - 1 do term.fill(y, " ", TEXT) end
  local y = ROWS // 2 - 9
  for r = 1, 5 do
    local t = {}
    for ch in ("TRADER"):gmatch(".") do t[#t + 1] = LETTERS[ch][r] end
    local line = table.concat(t, " "):gsub("#", "\u{2588}")
    put((COLS - 35) // 2, y + r, line, r <= 2 and GOLD or r == 3 and 0x06 or 0x06)
  end
  local function center(yy, s, a) put((COLS - len(s)) // 2, yy, s, a) end
  center(y + 7, "A real-time stock market game", CYAN)
  center(y + 8, "$10,000 to start \u{00B7} 20 trading days \u{00B7} 2x leverage", DIM)
  local items = {{"N", "New game"}}
  if g then
    items[#items + 1] = {"C", string.format("Continue (day %d, %s)", g.m.day, money((book.value(g.b, g.m))))}
  end
  items[#items + 1] = {"S", "High scores"}
  items[#items + 1] = {"H", "How to play"}
  items[#items + 1] = {"Q", "Quit"}
  for k, it in ipairs(items) do
    local x = put((COLS - 30) // 2, y + 9 + 2 * k, " " .. it[1] .. " ", SEL)
    put(x + 2, y + 9 + 2 * k, it[2], BRIGHT)
  end
  local best = save.scores()[1]
  if best then center(y + 21, "Best: " .. best.n .. " " .. money(best.s), GOLD) end
end

-- The ticker tape at the bottom of the title screen, from a demo market.
local function tape(demo)
  local chars, attrs = {}, {}
  local function add(s, a)
    for _, c in utf8.codes(s) do
      chars[#chars + 1], attrs[#attrs + 1] = utf8.char(c), a
    end
  end
  for i, co in ipairs(market.CO) do
    local s = demo.stocks[i]
    local up = s.p >= s.prev
    add(co.sym .. " ", BRIGHT)
    add(money(s.p) .. " ", TEXT)
    add((up and "\u{25B2}" or "\u{25BC}") .. pct(s.p, s.prev):sub(2) .. "   ", up and UP or DOWN)
  end
  return chars, attrs
end

-- → the key picked: "n", "c", "s", "h" or "q"
local function title(demo, g)
  drawtitle(g)
  local chars, attrs = tape(demo)
  local off, tick, scroll = 0, sys.millis(), 0
  while true do
    for e in key.poll do
      local k = e.type == "key" and e.key or e.type == "char" and e.ch:lower()
      if k == "enter" then k = g and "c" or "n" end
      if k == "esc" then k = "q" end
      if k == "n" or k == "s" or k == "h" or k == "q" or (k == "c" and g) then return k end
    end
    local now = sys.millis()
    if now - tick >= TICK_MS then
      tick = now
      market.tick(demo)
      if demo.t >= market.TICKS then
        market.close(demo)
        market.open(demo)
      end
      chars, attrs = tape(demo)
    end
    if now - scroll >= 120 then
      scroll = now
      off = off + 1
      local y = ROWS - 2
      for x = 0, COLS - 1 do
        local k = (off + x) % #chars + 1
        term.cell(x, y, chars[k], attrs[k])
      end
    end
    sys.yield()
  end
end

local function main()
  term.showcursor(false)
  term.cls()
  math.randomseed(sys.random(1000000), sys.millis())
  local demo = market.new()
  while true do
    local g = save.game()
    local k = title(demo, g)
    if k == "q" then return end
    if k == "n" and g then
      box("NEW GAME", {"This replaces the saved game.", "", "Y to go on, any other key to cancel"})
      local e = anykey()
      if not (e.type == "char" and e.ch:lower() == "y") then k = nil end
    end
    if k == "n" or k == "c" then
      local G = g
      if k == "n" then
        G = {m = market.new(), b = book.new(N), sel = 1, lot = 3, chart = "day", dayStart = book.START}
        say(G, "Day 1: the market is open. H for help.", CYAN)
      else
        say(G, string.format("Welcome back: day %d goes on.", G.m.day), CYAN)
      end
      local r = play(G)
      if r ~= "quit" then gameover(G, r == "bankrupt") end
    elseif k == "s" then
      scores()
    elseif k == "h" then
      help()
    end
  end
end

local ok, err = pcall(main)
term.cls()
term.showcursor(true)
sys.saver(true)
if not ok then error(err, 0) end
