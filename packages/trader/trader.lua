-- trader: paper trading on real US stocks. Prices come from Yahoo Finance
-- every minute while the New York exchange is open. You start with a
-- virtual $100,000, may sell short and hold up to twice your net worth,
-- and race the S&P 500. The account is kept in /.trader/paper.lua.
-- Keys: Up/Down pick a stock, B buy, S sell or short, C close the
-- position, +/- lot size, Tab today or 3-month chart, A add a stock,
-- D drop it, U update now, R reset the account, H help, Q or Esc quit.
if not termina then
  print("trader needs TERMINA 4.0.0 or later")
  return
end
local term, key, sys, sound = termina.term, termina.key, termina.sys, termina.sound
local quotes = require "trader.quotes"
local book = require "trader.book"
local save = require "trader.save"

local COLS, ROWS = term.cols(), term.rows()
if COLS < 80 or ROWS < 30 then
  print("trader needs a screen of 80x30 or more")
  return
end

local LOTS = {1, 10, 100, 1000, 0}    -- 0: the most the account allows
local MAX_LIST = 16
local OPEN_MS, CLOSED_MS = 60000, 600000  -- time between updates: market open, closed
local BENCH = "SPY"                        -- the S&P 500 to race
local DEFAULT = {"AAPL", "MSFT", "NVDA", "TSLA", "AMZN", "GOOGL", "META", "NFLX", "AMD", "KO"}
local NAMES = {AAPL = "Apple", MSFT = "Microsoft", NVDA = "NVIDIA", TSLA = "Tesla", AMZN = "Amazon",
               GOOGL = "Alphabet", META = "Meta Platforms", NFLX = "Netflix", AMD = "Advanced Micro Devices",
               KO = "Coca-Cola", SPY = "SPDR S&P 500 ETF"}
local WIDE = COLS >= 100
local LW = WIDE and 44 or 33          -- width of the left column
local LOG_N = ROWS >= 40 and 8 or 6   -- lines of activity
local TOPB = ROWS - 5 - LOG_N         -- last row of the stocks and the chart
local LISTB = TOPB - 6                -- last row of the stock list

local TEXT, DIM, BRIGHT, SEL, CYAN = 0x07, 0x08, 0x0F, 0x70, 0x0B
local UP, DOWN, GOLD, BAR, ALERT = 0x0A, 0x0C, 0x0E, 0x1F, 0x4F
local BOX, BOXHI, BOXUP, BOXDOWN = 0x1F, 0x1E, 0x1A, 0x1C

-- Drawing goes to a back buffer, and flush() sends the screen only the
-- cells that changed: a frame is never seen half drawn, and a refresh only
-- costs the few cells that moved.
local scr = {}
do
  local bc, ba, fc, fa = {}, {}, {}, {}  -- back and front: character, attribute

  function scr.cell(x, y, ch, a)
    if x >= 0 and x < COLS and y >= 1 and y < ROWS then
      local k = y * COLS + x + 1
      bc[k], ba[k] = ch, a or TEXT
    end
  end

  function scr.put(x, y, s, a)  -- → width
    local n = 0
    for _, c in utf8.codes(s) do
      scr.cell(x + n, y, utf8.char(c), a)
      n = n + 1
    end
    return n
  end

  function scr.fill(y, ch, a)
    for x = 0, COLS - 1 do scr.cell(x, y, ch or " ", a) end
  end

  function scr.flush()
    for y = 1, ROWS - 1 do
      for x = 0, COLS - 1 do
        local k = y * COLS + x + 1
        local ch, a = bc[k] or " ", ba[k] or TEXT
        if ch ~= fc[k] or a ~= fa[k] then
          term.cell(x, y, ch, a)
          fc[k], fa[k] = ch, a
        end
      end
    end
  end
end

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

local function dur(s)  -- seconds → "2h14" or "14 min"
  if s >= 3600 then return string.format("%dh%02d", s // 3600, s % 3600 // 60) end
  return string.format("%d min", (s + 59) // 60)
end

local function len(s) return utf8.len(s) or #s end

local function cut(s, n)
  if n <= 0 then return "" end
  if len(s) <= n then return s end
  return s:sub(1, (utf8.offset(s, n + 1) or #s + 1) - 1)
end

local function put(x, y, s, a, w)  -- → the column after the text
  if w then s = cut(s, w) end
  return x + scr.put(x, y, s, a)
end

local function rput(x, y, s, a)  -- right-aligned, ending at column x
  scr.put(x - len(s) + 1, y, s, a)
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
    scr.put(x, yy, string.rep(edge and "\u{2500}" or " ", w), BOX)
    scr.cell(x, yy, r == 0 and "\u{256D}" or r == h - 1 and "\u{2570}" or "\u{2502}", BOX)
    scr.cell(x + w - 1, yy, r == 0 and "\u{256E}" or r == h - 1 and "\u{256F}" or "\u{2502}", BOX)
  end
  put(x + (w - len(title) - 2) // 2, y, " " .. title .. " ", BOXHI)
  for k, l in ipairs(lines) do
    local t, a = l, BOX
    if type(l) == "table" then t, a = l[1], l[2] end
    put(x + 2, y + 1 + k, t, a, w - 4)
  end
  scr.flush()
end

local HELP = {
  "Real US stocks at their real prices (Yahoo Finance, updated",
  "every minute), with $100,000 of play money that stays yours.",
  "",
  {"B buys and S sells the lot (+/- to change it; MAX is all", BOXHI},
  {"you can). Selling what you don't own is a short sale: it", BOXHI},
  {"makes money when the price falls. C closes a position.", BOXHI},
  "Orders fill at a fresh quote, while New York is open",
  "(9:30 to 16:00 there, Monday to Friday). No fees.",
  "",
  "You may hold up to 2x your net worth. Borrowed cash costs",
  "0.02% a day, shorts 0.01% of their value.",
  {"Margin call: when net worth falls under 30% of what you", BOXDOWN},
  {"hold, your biggest positions are sold at once.", BOXDOWN},
  "",
  "A adds a stock (ticker symbol), D drops one, U updates now,",
  "R starts over. Can you beat the S&P 500?",
}

-- ------------------------------------------------------------------- state

local S  -- the saved account: list, names, b, start = {t, spy}, day, log, sel, lot, chart
local R = {px = {}, prev = {}, last = {}, intra = {}, daily = {}, next = 0, top = 0}  -- what was fetched

local function fresh(list, names)
  local l = {}
  for i, s in ipairs(list or DEFAULT) do l[i] = s end
  return {list = l, names = names or {}, b = book.new(), start = {}, log = {}, sel = 1, lot = 3, chart = "today"}
end

local function name(s) return S.names[s] or NAMES[s] or s end

local function find(list, s)
  for i, x in ipairs(list) do if x == s then return i end end
end

local function now()  -- UTC seconds, nil until the clock is set from the network
  local t = sys.epoch()
  if t and t > 1600000000 then return t end
end

local function isopen()
  local t = now()
  return t and R.sess and t >= R.sess.open and t < R.sess.close or false
end

local function nyday(t) return (t + (R.sess and R.sess.off or -18000)) // 86400 end

local function log(text, tone)
  table.insert(S.log, 1, {d = os.date("%b %d %H:%M"), text = text, tone = tone or 0})
  if #S.log > 30 then table.remove(S.log) end
end

local function say(s, a) R.msg, R.msgA = s, a or TEXT end

-- ------------------------------------------------------------------ screen

local function titlebar()
  scr.fill(1, " ", BAR)
  local x = put(1, 1, "TRADER", BAR | 0x0E)
  local t, st = now(), nil
  if not t then
    st = "waiting for the clock"
  elseif isopen() then
    st = "New York open, closes in " .. dur(R.sess.close - t)
  elseif R.sess and t < R.sess.open then
    st = "New York closed, opens " .. os.date("%a %H:%M", R.sess.open)
    if R.sess.open - t < 86400 then st = st .. " (in " .. dur(R.sess.open - t) .. ")" end
  else
    st = "New York closed"
  end
  put(x + 2, 1, st, BAR)
  local right, a
  if R.busy then
    right, a = R.busy .. "\u{2026}", BAR | 0x0E
  elseif R.err then
    right, a = "offline: " .. R.err, (BAR & 0xF0) | 0x0C
  else
    right, a = "update in " .. math.max(0, (R.next - sys.millis()) // 1000) .. "s", BAR
  end
  rput(COLS - 2, 1, cut(right, 30), a)
end

local function stockrow(i, y)
  local s = S.list[i]
  local px, prev, sel = R.px[s], R.prev[s], i == S.sel
  local bg = sel and SEL or TEXT
  local function fg(c) return sel and (0x70 | (c & 0x07)) or c end
  scr.put(0, y, string.rep(" ", LW), bg)
  put(0, y, sel and "\u{25B6}" or " ", sel and 0x70 or DIM)
  put(1, y, s, sel and 0x70 or BRIGHT, 6)
  if px then
    local last = R.last[s] or px
    rput(16, y, money(px), px > last and fg(UP) or px < last and fg(DOWN) or bg)
    if prev then rput(24, y, pct(px, prev), fg(px >= prev and UP or DOWN)) end
  else
    rput(16, y, "--", sel and 0x70 or DIM)
  end
  local q = S.b.pos[s]
  if q then
    rput(31, y, qty(q), fg(q > 0 and CYAN or GOLD))
    if WIDE and px then
      local u = (px - S.b.cost[s]) * q
      rput(42, y, short(u, true), fg(u >= 0 and UP or DOWN))
    end
  else
    rput(31, y, "-", sel and 0x70 or DIM)
  end
end

local function detail()
  local s = S.list[S.sel]
  if not s then return end
  local y, w, px = TOPB - 4, LW - 2, R.px[s]
  put(1, y, name(s), BRIGHT, w)
  local d = R.intra[s]
  if d and #d.c > 0 then
    local lo, hi = d.c[1], d.c[1]
    for _, p in ipairs(d.c) do
      if p < lo then lo = p end
      if p > hi then hi = p end
    end
    put(1, y + 1, "Day range " .. money(lo) .. " - " .. money(hi), DIM, w)
  end
  local q = S.b.pos[s]
  if not q then
    put(1, y + 2, "No position", DIM)
  else
    local cost = S.b.cost[s]
    put(1, y + 2, string.format("%s %s @ %s", q > 0 and "Long" or "Short", qty(math.abs(q)), money(cost)),
        q > 0 and CYAN or GOLD, w)
    if px then
      local u = (px - cost) * q
      put(1, y + 3, "P&L " .. money(u, true) .. "  " .. pct(px, cost), u >= 0 and UP or DOWN, w)
    end
  end
  local x = put(1, y + 4, "Lot", TEXT)
  x = put(x + 1, y + 4, " " .. (LOTS[S.lot] == 0 and "MAX" or qty(LOTS[S.lot])) .. " ", SEL)
  if px then
    put(x + 1, y + 4, string.format("max B %s S %s", qty(book.max(S.b, R.px, s, 1)), qty(book.max(S.b, R.px, s, -1))),
        DIM, LW - x - 2)
  end
end

-- Candles from closing prices, per closes in each.
local function candles(cl, per, first)
  local cs, prev = {}, first or cl[1]
  for j = 1, #cl, per do
    local o, h, l, c = prev, prev, prev, prev
    for k = j, math.min(j + per - 1, #cl) do
      local p = cl[k]
      if p > h then h = p end
      if p < l then l = p end
      c = p
    end
    cs[#cs + 1] = {o, h, l, c}
    prev = c
  end
  return cs
end

local function chart()
  local x0, w = LW + 2, COLS - LW - 3
  local s = S.list[S.sel]
  if not s then return end
  local pw = w - 10  -- candle columns; the price scale takes the rest
  local today = S.chart == "today"
  local px, prev, cs = R.px[s], R.prev[s], nil
  if today and R.intra[s] and #R.intra[s].c > 0 then
    cs = candles(R.intra[s].c, (78 + pw - 1) // pw, prev)  -- 78 bars of 5 minutes a day
  elseif not today and R.daily[s] and #R.daily[s] > 1 then
    local d, from = R.daily[s], math.max(1, #R.daily[s] - pw + 1)
    local cl = table.move(d, from, #d, 1, {})
    cs = candles(cl, 1, d[from - 1])
  end
  local x = put(x0, 2, s, BRIGHT)
  put(x + 1, 2, today and "today, 5 min (Tab: 3 months)" or "3 months (Tab: today)", DIM, x0 + w - x - 1)
  if not cs then
    put(x0 + 2, 4, "No data yet", DIM)
    return
  end
  local lo, hi = math.maxinteger, 0
  for _, c in ipairs(cs) do
    if c[2] > hi then hi = c[2] end
    if c[3] < lo then lo = c[3] end
  end
  local cost = S.b.cost[s]
  if cost then
    if cost > hi then hi = cost end
    if cost < lo then lo = cost end
  end
  if hi - lo < 8 then hi, lo = hi + 4, lo - 4 end
  local top, h = 3, TOPB - 2
  local function row(p) return top + (hi - p) * (h - 1) // (hi - lo) end
  local sx = x0 + pw + 1
  if today and prev and prev >= lo and prev <= hi then
    local y = row(prev)
    for xx = x0, x0 + pw - 1 do scr.cell(xx, y, "\u{2504}", DIM) end
  end
  if cost then
    local y = row(cost)
    for xx = x0, x0 + pw - 1 do scr.cell(xx, y, "\u{2504}", GOLD) end
    put(sx, y, "cost", GOLD)
  end
  -- Candles in half rows: each text row holds an upper and a lower half,
  -- wick and body drawn with the half lines and half blocks.
  local function half(p) return (hi - p) * (2 * h - 1) // (hi - lo) end
  for k, c in ipairs(cs) do
    local xx, a = x0 + k - 1, c[4] >= c[1] and UP or DOWN
    local wt, wb = half(c[2]), half(c[3])
    local bt, bb = half(math.max(c[1], c[4])), half(math.min(c[1], c[4]))
    local doji = c[1] == c[4]
    for y = wt // 2, wb // 2 do
      local up, down = 2 * y, 2 * y + 1
      local w1, w2 = up >= wt and up <= wb, down >= wt and down <= wb
      local b1, b2 = up >= bt and up <= bb, down >= bt and down <= bb
      local ch
      if doji and (b1 or b2) then ch = "\u{2501}"
      elseif b1 and b2 then ch = "\u{2588}"
      elseif b1 then ch = w2 and "\u{257F}" or "\u{2580}"
      elseif b2 then ch = w1 and "\u{257D}" or "\u{2584}"
      elseif w1 and w2 then ch = "\u{2502}"
      elseif w1 then ch = "\u{2575}"
      elseif w2 then ch = "\u{2577}" end
      if ch then scr.cell(xx, top + y, ch, a) end
    end
  end
  put(sx, top, money(hi), DIM)
  put(sx, top + (h - 1) // 2, money((hi + lo) // 2), DIM)
  put(sx, top + h - 1, money(lo), DIM)
  if px then put(sx - 1, row(px), "\u{25C0}" .. money(px), (not prev or px >= prev) and 0x2F or 0x4F) end
end

local function activity()
  local y0 = TOPB + 1
  scr.fill(y0, "\u{2501}", DIM)
  put(2, y0, " ACTIVITY ", CYAN)
  for k = 1, LOG_N do
    local n = S.log[k]
    if n then
      local x = put(1, y0 + k, n.d .. " ", DIM)
      put(x, y0 + k, n.text, n.tone > 0 and UP or n.tone < 0 and DOWN or TEXT, COLS - x - 1)
    end
  end
end

local function portfolio()
  local y = ROWS - 3
  local eq = book.value(S.b, R.px)
  local lvl = book.level(S.b, R.px)
  local a = lvl and lvl < book.WARN and sys.millis() // 500 % 2 == 0 and ALERT or BAR
  scr.fill(y, " ", a)
  local sep = WIDE and " \u{E0B1} " or "\u{E0B1}"
  local bench = S.start.spy and R.px[BENCH] and (WIDE and "S&P 500 " or "S&P ") ..
                pct(R.px[BENCH], S.start.spy) .. sep or ""
  local s = (WIDE and " Net worth " or " Worth ") .. money(eq) .. " " .. pct(eq, book.START) .. sep .. bench ..
            "Cash " .. short(S.b.cash) .. sep .. "Power " .. short(math.max(0, book.power(S.b, R.px))) ..
            sep .. "Margin " .. (lvl and math.min(lvl, 999) .. "%" or "-")
  put(0, y, s, a, COLS - 1)
end

local KEYS = {{"\u{2191}\u{2193}", "Pick"}, {"B", "Buy"}, {"S", "Sell"}, {"C", "Close"}, {"Tab", "Chart"},
              {"A", "Add"}, {"D", "Drop"}, {"H", "Help"}, {"Q", "Quit"}}

local function draw()
  for y = 1, ROWS - 1 do scr.fill(y, " ", TEXT) end
  titlebar()
  put(1, 2, "SYM", DIM)
  rput(16, 2, "PRICE", DIM)
  rput(24, 2, "DAY", DIM)
  rput(31, 2, "POS", DIM)
  if WIDE then rput(42, 2, "P&L", DIM) end
  local rows = LISTB - 2
  if S.sel <= R.top then R.top = S.sel - 1 end
  if S.sel > R.top + rows then R.top = S.sel - rows end
  for k = 1, rows do
    if S.list[R.top + k] then stockrow(R.top + k, 2 + k) end
  end
  if R.top > 0 then put(LW - 2, 3, "\u{25B4}", DIM) end
  if R.top + rows < #S.list then put(LW - 2, LISTB, "\u{25BE}", DIM) end
  detail()
  for y = 2, TOPB do scr.cell(LW, y, "\u{2502}", DIM) end
  chart()
  activity()
  portfolio()
  put(1, ROWS - 2, R.msg or "", R.msgA or TEXT, COLS - 2)
  local x = 1
  for _, k in ipairs(KEYS) do
    x = put(x, ROWS - 1, k[1], BRIGHT)
    x = put(x + 1, ROWS - 1, k[2], DIM) + 2
  end
  scr.flush()
end

local function busy(text)  -- shown while a request blocks
  R.busy = text
  draw()
end

-- --------------------------------------------------------------- the market

local function symbols()
  local l = table.move(S.list, 1, #S.list, 1, {})
  for s in pairs(S.b.pos) do
    if not find(l, s) then l[#l + 1] = s end
  end
  if not find(l, BENCH) then l[#l + 1] = BENCH end
  return l
end

-- Interest once a New York day, the margin check, the benchmark's start.
local function settle()
  local t = now()
  if t and not S.start.spy and R.px[BENCH] then S.start.spy, S.start.t = R.px[BENCH], t end
  if t and R.sess then
    local day = nyday(t)
    if not S.day then
      S.day = day
    elseif day > S.day then
      local n, c = math.min(day - S.day, 30), 0
      for _ = 1, n do c = c + book.night(S.b, R.px) end
      S.day = day
      if c > 0 then log(string.format("Interest for %d day%s: %s", n, n > 1 and "s" or "", money(-c)), -1) end
    end
  end
  if isopen() then
    local sold = book.liquidate(S.b, R.px)
    if #sold > 0 then
      local t2 = {}
      for _, x in ipairs(sold) do t2[#t2 + 1] = qty(x.q) .. " " .. x.s .. " (" .. money(x.pnl, true) .. ")" end
      local msg = "MARGIN CALL: sold " .. table.concat(t2, ", ")
      log(msg, -1)
      say(msg, ALERT)
      sound.play("call:d=8,o=5,b=200:c,p,c,p,c")
    end
  end
  save.store(S)
end

local function update(full)
  busy("updating")
  local syms = symbols()
  local d, err = quotes.spark(syms, "1d", "5m")
  R.err = err
  if d then
    for s, v in pairs(d) do
      R.intra[s] = v
      R.last[s] = R.px[s]
      if #v.c > 0 then R.px[s] = v.c[#v.c] end
      R.prev[s] = v.prev
    end
    local t = now()
    if full or not R.sess or (t and t >= R.sess.close) then
      local q = quotes.quote(BENCH)
      if q and q.open and q.close then R.sess = {open = q.open, close = q.close, off = q.off} end
    end
    local day = t and nyday(t)
    if full or R.dailyDay ~= day then
      local h = quotes.spark(syms, "3mo", "1d")
      if h then
        for s, v in pairs(h) do R.daily[s] = v.c end
        R.dailyDay = day
      end
    end
  end
  R.busy = nil
  R.next = sys.millis() + ((isopen() or R.err) and OPEN_MS or CLOSED_MS)
  settle()
end

-- A fresh price for s before an order, or nil (said why).
local function fresh_price(s)
  if not isopen() then
    say("New York is closed: orders are taken from 9:30 to 16:00 there", DOWN)
    sound.tone(220, 80)
    return nil
  end
  busy("quote for " .. s)
  local q, err = quotes.quote(s)
  R.busy = nil
  if not q or not q.price then
    say("No quote for " .. s .. ": " .. (err or "no price"), DOWN)
    return nil
  end
  R.last[s], R.px[s] = R.px[s], q.price
  return q.price
end

local function order(dir)
  local s = S.list[S.sel]
  if not s then return end
  local p = fresh_price(s)
  if not p then return end
  local mx = book.max(S.b, R.px, s, dir)
  local want = LOTS[S.lot]
  local q = (want == 0 or want > mx) and mx or want
  if q <= 0 then
    say("Not enough buying power", DOWN)
    sound.tone(220, 80)
    return
  end
  local old = S.b.pos[s] or 0
  local pnl = book.trade(S.b, s, q * dir, p)
  local verb
  if dir > 0 then
    verb = old >= 0 and "Bought" or old + q <= 0 and "Covered" or "Covered and bought"
  else
    verb = old <= 0 and "Shorted" or old - q >= 0 and "Sold" or "Sold and shorted"
  end
  local msg = string.format("%s %s %s @ %s", verb, qty(q), s, money(p))
  if want ~= 0 and q < want then msg = msg .. " (all you could)" end
  if pnl ~= 0 then msg = msg .. ", P&L " .. money(pnl, true) end
  local tone = pnl > 0 and 1 or pnl < 0 and -1 or 0
  log(msg, tone)
  say(msg, tone > 0 and UP or tone < 0 and DOWN or BRIGHT)
  sound.tone(dir > 0 and 880 or 660, 25)
  save.store(S)
end

local function closepos()
  local s = S.list[S.sel]
  local q = s and S.b.pos[s]
  if not q then return say("No " .. (s or "") .. " position to close", DIM) end
  local p = fresh_price(s)
  if not p then return end
  local pnl = book.trade(S.b, s, -q, p)
  local msg = string.format("Closed %s %s @ %s, P&L %s", qty(math.abs(q)), s, money(p), money(pnl, true))
  log(msg, pnl >= 0 and 1 or -1)
  say(msg, pnl >= 0 and UP or DOWN)
  sound.tone(770, 25)
  save.store(S)
end

-- A line of text typed in a box → the text, or nil when cancelled.
local function prompt(title, help)
  local text = ""
  while true do
    box(title, {help, "", "> " .. text .. "_", "", "Enter to confirm, Esc to cancel"})
    local e = anykey()
    if e.type == "char" and #text < 12 and e.ch:match("^[%w%.%-%^=]$") then
      text = text .. e.ch:upper()
    elseif e.type == "key" and e.key == "backspace" then
      text = text:sub(1, -2)
    elseif e.type == "key" and e.key == "enter" then
      return text ~= "" and text or nil
    elseif e.type == "key" and e.key == "esc" then
      return nil
    end
  end
end

local function add()
  if #S.list >= MAX_LIST then return say("The list is full: drop a stock first (D)", DOWN) end
  local s = prompt("ADD A STOCK", "Ticker symbol of a US stock or fund: IBM, SPY, BRK-B...")
  if not s then return end
  local i = find(S.list, s)
  if i then
    S.sel = i
    return
  end
  busy("looking up " .. s)
  local q, err = quotes.quote(s)
  R.busy = nil
  if not q or not q.price then return say(s .. ": " .. (err or "no price"), DOWN) end
  if q.currency ~= "USD" then return say(s .. " is priced in " .. tostring(q.currency) .. ": US dollars only", DOWN) end
  if q.price > 9999999 then return say(s .. " costs too much for this game", DOWN) end
  S.list[#S.list + 1] = s
  S.names[s] = q.name
  S.sel = #S.list
  R.px[s], R.prev[s] = q.price, q.prev
  update(true)
  say("Added " .. s .. ", " .. q.name, CYAN)
end

local function drop()
  local s = S.list[S.sel]
  if not s then return end
  if S.b.pos[s] then return say("Close your " .. s .. " position before dropping it", DOWN) end
  table.remove(S.list, S.sel)
  S.names[s] = nil
  S.sel = math.max(1, math.min(S.sel, #S.list))
  save.store(S)
  say("Dropped " .. s)
end

local function reset()
  box("START OVER", {"This sells everything and puts the account back", "to $100,000. The stock list stays.",
                     "", "Y to go on, any other key to cancel"})
  local e = anykey()
  if e.type == "char" and e.ch:lower() == "y" then
    S = fresh(S.list, S.names)
    log("New account: $100,000", 0)
    settle()
    say("A new start. Good luck!", CYAN)
  end
end

local LETTERS = {
  T = {"#####", "  #  ", "  #  ", "  #  ", "  #  "},
  R = {"#### ", "#   #", "#### ", "#  # ", "#   #"},
  A = {" ### ", "#   #", "#####", "#   #", "#   #"},
  D = {"#### ", "#   #", "#   #", "#   #", "#### "},
  E = {"#####", "#    ", "#### ", "#    ", "#####"},
}

local function splash()
  for y = 1, ROWS - 1 do scr.fill(y, " ", TEXT) end
  local y = ROWS // 2 - 6
  for r = 1, 5 do
    local t = {}
    for ch in ("TRADER"):gmatch(".") do t[#t + 1] = LETTERS[ch][r] end
    local line = table.concat(t, " "):gsub("#", "\u{2588}")
    put((COLS - 35) // 2, y + r, line, r <= 2 and GOLD or 0x06)
  end
  local function center(yy, s, a) put((COLS - len(s)) // 2, yy, s, a) end
  center(y + 7, "Paper trading on the real stock market", CYAN)
  center(y + 9, "Fetching prices from Yahoo Finance\u{2026}", DIM)
  scr.flush()
end

-- -------------------------------------------------------------------- main

local function main()
  term.showcursor(false)
  term.cls()
  S = save.load()
  if not S then
    S = fresh()
    log("New account: $100,000", 0)
  end
  splash()
  update(true)
  say(R.err and "No prices: " .. R.err or "H for help", R.err and DOWN or CYAN)
  local wasopen, second = isopen(), -1
  while true do
    local dirty = false
    for e in key.poll do
      local k = e.type == "key" and e.key or e.type == "char" and e.ch:lower()
      local n = #S.list
      if k == "up" and n > 0 then S.sel = (S.sel - 2) % n + 1
      elseif k == "down" and n > 0 then S.sel = S.sel % n + 1
      elseif k == "pgup" then S.sel = math.max(1, S.sel - (LISTB - 2))
      elseif k == "pgdn" then S.sel = math.max(1, math.min(n, S.sel + (LISTB - 2)))
      elseif k == "b" then order(1)
      elseif k == "s" then order(-1)
      elseif k == "c" then closepos()
      elseif k == "+" or k == "=" or k == "right" then S.lot = math.min(#LOTS, S.lot + 1)
      elseif k == "-" or k == "left" then S.lot = math.max(1, S.lot - 1)
      elseif k == "tab" then S.chart = S.chart == "today" and "daily" or "today"
      elseif k == "a" or k == "insert" then add()
      elseif k == "d" or k == "delete" then drop()
      elseif k == "u" then R.next = 0
      elseif k == "r" then reset()
      elseif k == "h" or k == "f1" then
        box("HOW TO PLAY", HELP)
        anykey()
      elseif k == "q" or k == "esc" then
        save.store(S)
        return
      elseif e.type == "mouse" and e.down and e.x < LW and e.y >= 3 and e.y <= LISTB then
        local i = R.top + e.y - 2
        if S.list[i] then S.sel = i end
      end
      dirty = true
    end
    if sys.millis() >= R.next then
      update(false)
      dirty = true
    end
    local open = isopen()
    if open ~= wasopen then
      wasopen = open
      log(open and "The New York market opens" or "The New York market closes", 0)
      sound.play("bell:d=4,o=6,b=120:c,8p,c")
      R.next = 0  -- the opening or closing prices
    end
    local sec = sys.millis() // 1000
    if sec ~= second then
      second = sec
      dirty = true
    end
    if dirty then draw() end
    sys.yield()
  end
end

local ok, err = pcall(main)
term.cls()
term.showcursor(true)
if not ok then error(err, 0) end
