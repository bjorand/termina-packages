-- trader.book: the paper trading account. Money is integer cents,
-- positions are share counts by symbol (negative: sold short). Equity is
-- the cash plus what the positions are worth; holdings may reach LEVER
-- times the equity, and below MAINT % of equity over holdings the biggest
-- positions get sold. px is a table of prices in cents by symbol.
local M = {}

M.START = 10000000    -- $100,000.00
M.LEVER = 2
M.MAINT = 30          -- margin call below this %
M.WARN = 40           -- warning below this %
local CAP = 1000000000             -- holdings limit ($10M): sums stay in 32-bit integers
local LOAN_BPS, BORROW_BPS = 2, 1  -- per day: on borrowed cash, on the value of shorts

function M.new()
  return {cash = M.START, pos = {}, cost = {}, trades = 0, interest = 0, realized = 0,
          best = 0, worst = 0, calls = 0}
end

local function price(b, px, s) return px[s] or b.cost[s] end

-- → equity, gross holdings (longs plus shorts, at the last prices)
function M.value(b, px)
  local eq, gross = b.cash, 0
  for s, q in pairs(b.pos) do
    local v = q * price(b, px, s)
    eq = eq + v
    gross = gross + (v < 0 and -v or v)
  end
  return eq, gross
end

-- Holdings that can still be added (negative: over the limit).
function M.power(b, px)
  local eq, gross = M.value(b, px)
  return math.min(eq, CAP // M.LEVER) * M.LEVER - gross
end

-- The most shares of s one order can buy (dir 1) or sell (dir -1):
-- closing a position is always allowed, going further takes buying power.
function M.max(b, px, s, dir)
  local q = (b.pos[s] or 0) * dir
  local back = q < 0 and -q or 0
  return math.max(back, 2 * back + M.power(b, px) // px[s], 0)
end

-- Buys qty shares of s at price p (sells when negative) → profit of the
-- part that closed a position.
function M.trade(b, s, qty, p)
  local old, cost = b.pos[s] or 0, b.cost[s] or 0
  local new = old + qty
  local pnl = 0
  if old ~= 0 and (old > 0) ~= (qty > 0) then
    local closed = math.min(math.abs(qty), math.abs(old))
    pnl = (p - cost) * closed * (old > 0 and 1 or -1)
    b.realized = b.realized + pnl
    if pnl > b.best then b.best = pnl end
    if pnl < b.worst then b.worst = pnl end
  end
  if new == 0 then
    cost = nil
  elseif old == 0 or (old > 0) ~= (new > 0) then
    cost = p
  elseif (old > 0) == (qty > 0) then
    cost = (cost * math.abs(old) + p * math.abs(qty)) // math.abs(new)
  end
  b.pos[s] = new ~= 0 and new or nil
  b.cost[s] = cost
  b.cash = b.cash - qty * p
  b.trades = b.trades + 1
  return pnl
end

-- A day of interest → what it cost.
function M.night(b, px)
  local c = 0
  if b.cash < 0 then c = c + (-b.cash) // 10000 * LOAN_BPS end
  for s, q in pairs(b.pos) do
    if q < 0 then c = c + (-q * price(b, px, s)) // 10000 * BORROW_BPS end
  end
  b.cash = b.cash - c
  b.interest = b.interest + c
  return c
end

-- Equity over holdings in % (nil without holdings).
function M.level(b, px)
  local eq, gross = M.value(b, px)
  if gross < 100 then return nil end
  return eq // (gross // 100)
end

-- Margin call: sells the biggest positions until back above MAINT
-- → {{s, q, pnl}...} what was sold.
function M.liquidate(b, px)
  local sold = {}
  while true do
    local lvl = M.level(b, px)
    if not lvl or lvl >= M.MAINT then break end
    local big, bv = nil, 0
    for s, q in pairs(b.pos) do
      local v = math.abs(q * price(b, px, s))
      if v > bv then big, bv = s, v end
    end
    if not big then break end
    local q = b.pos[big]
    sold[#sold + 1] = {s = big, q = q, pnl = M.trade(b, big, -q, price(b, px, big))}
  end
  if #sold > 0 then b.calls = b.calls + 1 end
  return sold
end

return M
