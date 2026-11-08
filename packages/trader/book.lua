-- trader.book: the player's account. Money is integer cents, positions
-- are share counts (negative: sold short). Equity is the cash plus what
-- the positions are worth; holdings may reach LEVER times the equity, and
-- below MAINT % of equity over holdings the biggest positions get sold.
local M = {}

M.START = 1000000     -- $10,000.00
M.FEE = 500           -- per order
M.LEVER = 2
M.MAINT = 30          -- margin call below this %
M.WARN = 40           -- warning below this %
local CAP = 1000000000          -- holdings limit ($10M): sums stay in 32-bit integers
local LOAN_BPS, BORROW_BPS = 8, 5  -- per night: on borrowed cash, on the value of shorts

function M.new(n)
  local b = {cash = M.START, pos = {}, cost = {}, trades = 0, fees = 0, interest = 0,
             best = 0, worst = 0, calls = 0}
  for i = 1, n do b.pos[i], b.cost[i] = 0, 0 end
  return b
end

-- → equity, gross holdings (longs plus shorts, at today's prices)
function M.value(b, m)
  local eq, gross = b.cash, 0
  for i, q in ipairs(b.pos) do
    local v = q * m.stocks[i].p
    eq = eq + v
    gross = gross + (v < 0 and -v or v)
  end
  return eq, gross
end

-- Holdings that can still be added (negative: over the limit).
function M.power(b, m)
  local eq, gross = M.value(b, m)
  return math.min(eq - M.FEE, CAP // M.LEVER) * M.LEVER - gross
end

-- The most shares of stock i one order can buy (dir 1) or sell (dir -1):
-- closing a position is always allowed, going further takes buying power.
function M.max(b, m, i, dir)
  local q = b.pos[i] * dir
  local back = q < 0 and -q or 0
  return math.max(back, 2 * back + M.power(b, m) // m.stocks[i].p, 0)
end

-- Buys qty shares (sells when negative) at the current price → profit of
-- the part that closed a position.
function M.trade(b, m, i, qty, nofee)
  local p, old = m.stocks[i].p, b.pos[i]
  local new = old + qty
  local pnl = 0
  if old ~= 0 and (old > 0) ~= (qty > 0) then
    local closed = math.min(math.abs(qty), math.abs(old))
    pnl = (p - b.cost[i]) * closed * (old > 0 and 1 or -1)
    if pnl > b.best then b.best = pnl end
    if pnl < b.worst then b.worst = pnl end
  end
  if new == 0 then
    b.cost[i] = 0
  elseif old == 0 or (old > 0) ~= (new > 0) then
    b.cost[i] = p
  elseif (old > 0) == (qty > 0) then
    b.cost[i] = (b.cost[i] * math.abs(old) + p * math.abs(qty)) // math.abs(new)
  end
  b.pos[i] = new
  b.cash = b.cash - qty * p
  if not nofee then
    b.cash = b.cash - M.FEE
    b.fees = b.fees + M.FEE
    b.trades = b.trades + 1
  end
  return pnl
end

-- Overnight interest → what it cost.
function M.night(b, m)
  local c = 0
  if b.cash < 0 then c = c + (-b.cash) // 10000 * LOAN_BPS end
  for i, q in ipairs(b.pos) do
    if q < 0 then c = c + (-q * m.stocks[i].p) // 10000 * BORROW_BPS end
  end
  b.cash = b.cash - c
  b.interest = b.interest + c
  return c
end

-- Equity over holdings in % (nil without holdings).
function M.level(b, m)
  local eq, gross = M.value(b, m)
  if gross < 100 then return nil end
  return eq // (gross // 100)
end

-- Margin call: sells the biggest positions until back above MAINT
-- → {{i, q}...} what was sold.
function M.liquidate(b, m)
  local sold = {}
  while true do
    local lvl = M.level(b, m)
    if not lvl or lvl >= M.MAINT then break end
    local big, bv = nil, 0
    for i, q in ipairs(b.pos) do
      local v = math.abs(q * m.stocks[i].p)
      if v > bv then big, bv = i, v end
    end
    if not big then break end
    sold[#sold + 1] = {i = big, q = b.pos[big]}
    M.trade(b, m, big, -b.pos[big])
  end
  if #sold > 0 then b.calls = b.calls + 1 end
  return sold
end

-- The final bell: everything is closed at the last prices, without fees.
function M.closeall(b, m)
  for i, q in ipairs(b.pos) do
    if q ~= 0 then M.trade(b, m, i, -q, true) end
  end
end

return M
