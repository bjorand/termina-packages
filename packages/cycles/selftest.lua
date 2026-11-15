-- cycles.selftest: checks the pattern engine, the mini-notation, the code
-- translation and the scheduler (with a pretend sound card and clock).
--   lua /pkg/cycles/selftest.lua
-- Prints (and logs on the serial port) one line per failure, then a total.
local P = require "cycles.pattern"
local mini = require "cycles.mini"
local C = require "cycles.controls"
local dsl = require "cycles.dsl"
local Player = require "cycles.player"

local passed, failed = 0, 0
local function report(s)
  print(s)
  if termina and termina.sys and termina.sys.log then termina.sys.log("CYCLES " .. s) end
end
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    report("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
  end
end

local frac, span = P.frac, P.span

-- Onsets of p in cycles [b, e) as "value@time" strings, sorted by time,
-- then by text.
local function events(p, b, e)
  local hs = p.query(span(P.time(b or 0), P.time(e or 1)))
  local s = {}
  for _, h in ipairs(hs) do
    if P.onset(h) then
      local v = h.value
      if type(v) == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local kv = {}
        for j, k in ipairs(keys) do kv[j] = k .. "=" .. tostring(v[k]) end
        v = table.concat(kv, ",")
      end
      s[#s + 1] = {b = h.whole.b, text = tostring(v) .. "@" .. P.show(h.whole.b) .. "-" .. P.show(h.whole.e)}
    end
  end
  table.sort(s, function(x, y)
    if x.b == y.b then return x.text < y.text end
    return x.b < y.b
  end)
  for i, x in ipairs(s) do s[i] = x.text end
  return table.concat(s, " ")
end

local function same(name, got, want) check(name, got == want, "got [" .. got .. "] want [" .. want .. "]") end

local function miniEvents(src, b, e)
  local ok, p = pcall(mini.parse, src)
  if not ok then return "error: " .. tostring(p) end
  return events(p, b, e)
end

-- -------------------------------------------------------------------- time
check("1/3+2/3", frac(1, 3) + frac(2, 3) == P.T)
check("1/2<2/3", frac(1, 2) < frac(2, 3))
check("-1/2 sam", P.sam(frac(-1, 2)) == frac(-1))
check("0.25", P.time(0.25) == frac(1, 4))
check("1000.5", P.time(1000.5) == frac(2001, 2))
check("show", P.show(frac(1, 3)) == "1/3" and P.show(frac(-1, 4)) == "-1/4" and P.show(frac(2)) == "2")
do
  local n, d = P.ratio(0.6)
  check("ratio 0.6", n == 3 and d == 5)
  n, d = P.ratio(0.1)
  check("ratio 0.1", n == 1 and d == 10)
end
check("scale big", P.scale(90000 * P.T + 7, 16, 15) == (90000 * P.T + 7) // 15 * 16 + ((90000 * P.T + 7) % 15 * 16) // 15)
check("scale exact", P.scale(frac(5, 3), 3, 5) == frac(1))

-- ------------------------------------------------------------ mini-notation
same("seq", miniEvents("a b c"), "a@0-1/3 b@1/3-2/3 c@2/3-1")
same("sub", miniEvents("[a b] c"), "a@0-1/4 b@1/4-1/2 c@1/2-1")
same("alt0", miniEvents("<a b>", 0, 1), "a@0-1")
same("alt1", miniEvents("<a b>", 1, 2), "b@1-2")
same("alt sub", miniEvents("<a [b c]>", 1, 2), "b@1-3/2 c@3/2-2")
same("fast", miniEvents("a*2 b"), "a@0-1/4 a@1/4-1/2 b@1/2-1")
same("slow", miniEvents("a/2", 0, 2), "a@0-2")
same("weight", miniEvents("a@3 b"), "a@0-3/4 b@3/4-1")
same("repeat", miniEvents("a!3 b"), "a@0-1/4 a@1/4-1/2 a@1/2-3/4 b@3/4-1")
same("bang", miniEvents("a ! b"), "a@0-1/3 a@1/3-2/3 b@2/3-1")
same("elongate", miniEvents("a _ b"), "a@0-2/3 b@2/3-1")
same("rest", miniEvents("a ~ b -"), "a@0-1/4 b@1/2-3/4")
same("stack", miniEvents("a, b c"), "a@0-1 b@0-1/2 c@1/2-1")
same("chord", miniEvents("[c3,e3] g3"), "c3@0-1/2 e3@0-1/2 g3@1/2-1")
same("feet", miniEvents("a . b c"), "a@0-1/2 b@1/2-3/4 c@3/4-1")
same("euclid", miniEvents("x(3,8)"), "x@0-1/8 x@3/8-1/2 x@3/4-7/8")
same("euclid rot", miniEvents("x(3,8,2)"), "x@1/8-1/4 x@1/2-5/8 x@3/4-7/8")
same("euclid 5", miniEvents("x(5,8)"), "x@0-1/8 x@1/4-3/8 x@3/8-1/2 x@5/8-3/4 x@3/4-7/8")
same("euclid pat", miniEvents("x(<3 5>,8)", 1, 2), "x@1-9/8 x@5/4-11/8 x@11/8-3/2 x@13/8-7/4 x@7/4-15/8")
same("factor pat", miniEvents("a*<1 2>", 1, 2), "a@1-3/2 a@3/2-2")
same("numbers", miniEvents("1 -2 0.5"), "1@0-1/3 -2@1/3-2/3 0.5@2/3-1")
same("words", miniEvents("bd:3 c#4"), "bd:3@0-1/2 c#4@1/2-1")
same("alt stack", miniEvents("<a b, c d e>", 2, 3), "a@2-3 e@2-3")
do
  local n = 0
  for c = 0, 199 do
    local hs = mini.parse("a?").query(span(frac(c), frac(c + 1)))
    n = n + #hs
  end
  check("degrade ~half", n > 70 and n < 130, n)
  local again = 0
  for c = 0, 199 do again = again + #mini.parse("a?").query(span(frac(c), frac(c + 1))) end
  check("degrade repeatable", n == again)
  local seen = {}
  for c = 0, 29 do
    for _, h in ipairs(mini.parse("[a|b|c]").query(span(frac(c), frac(c + 1)))) do seen[h.value] = true end
  end
  check("choice", seen.a and seen.b and seen.c)
end
check("bad mini", not pcall(mini.parse, "[a b"))
check("bad mini 2", not pcall(mini.parse, "a ]"))

-- ------------------------------------------------------------------ methods
local m = P.methods
same("rev", events(m.rev(mini.parse("a b c"))), "c@0-1/3 b@1/3-2/3 a@2/3-1")
same("every 0", events(m.every(mini.parse("a b"), 2, function(x) return m.fast(x, 2) end), 0, 1),
     "a@0-1/4 b@1/4-1/2 a@1/2-3/4 b@3/4-1")
same("every 1", events(m.every(mini.parse("a b"), 2, function(x) return m.fast(x, 2) end), 1, 2),
     "a@1-3/2 b@3/2-2")
same("ply", events(m.ply(mini.parse("a b"), 2)), "a@0-1/4 a@1/4-1/2 b@1/2-3/4 b@3/4-1")
same("late", events(m.late(mini.parse("a b"), 0.25)), "a@1/4-3/4 b@3/4-5/4")
same("iter", events(m.iter(mini.parse("a b c d"), 4), 1, 2), "b@1-5/4 c@5/4-3/2 d@3/2-7/4 a@7/4-2")
same("off", events(m.off(mini.parse("a"), 0.5, function(x) return m.add(x, 1) end)), "a@0-1 58@1/2-3/2")
same("add", events(m.add(mini.parse("1 2"), "10")), "11@0-1/2 12@1/2-1")
same("segment", events(m.segment(P.saw, 4)), "0.0@0-1/4 0.25@1/4-1/2 0.5@1/2-3/4 0.75@3/4-1")
same("struct", events(m.struct(P.pure("x"), "t ~ t t")), "x@0-1/4 x@1/2-3/4 x@3/4-1")
same("weight 1.5", miniEvents("a@1.5 b"), "a@0-3/5 b@3/5-1")
do
  -- 11 steps: 11 does not divide the ticks of a cycle; steps stay end to
  -- end, none lost, none twice, over many small queries too.
  local p = mini.parse("0 1 2 3 4 5 6 7 8 9 10")
  local seen, ok, last = {}, true, nil
  for q = 0, 47 do
    for _, h in ipairs(p.query(span(P.T * q // 48, P.T * (q + 1) // 48))) do
      if P.onset(h) then
        if seen[h.value] then ok = false end
        seen[h.value] = true
      end
    end
  end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  check("11 steps", ok and n == 11, n)
end
do
  local p = m.fast(mini.parse("[a b c]"), 7)
  -- Cycle 10000, made 7 times faster: inner time near 70000 cycles, still
  -- within 32 bits.
  local hs = p.query(span(frac(10000), frac(10001)))
  check("far cycles", #hs == 21 and hs[1].whole.b >= frac(10000), #hs)
end

-- ----------------------------------------------------------------- controls
same("note", events(C.note("c e g")), "note=48@0-1/3 note=52@1/3-2/3 note=55@2/3-1")
same("note s", events(m.s(C.note("c a4"), "saw")), "note=48,s=saw@0-1/2 note=69,s=saw@1/2-1")
same("scale", events(m.scale(C.n("0 2 4 7"), "C:major")),
     "note=48@0-1/4 note=52@1/4-1/2 note=55@1/2-3/4 note=60@3/4-1")
same("scale neg", events(m.scale(C.n("-1"), "A3:minor")), "note=55@0-1")
same("s index", events(C.s("bd:3")), "n=3,s=bd@0-1")
same("note add", events(m.add(C.note("c"), 12)), "note=60@0-1")
do
  local r = C.render({note = 69, s = "square"})
  check("render hz", math.abs(r.hz - 440) < 0.5, r.hz)
  check("render duty", r.duty == 128, r.duty)
  check("render bd", C.render({s = "bd"}).drop ~= nil)
  check("render unknown", C.render({s = "nope"}) == nil)
  check("rate", C.rate(0.1) == 8 and C.rate(0) == 0 and C.rate(4) == 15)
end

-- ---------------------------------------------------------------------- dsl
do
  local t = dsl.translate("$: s(\"bd\")\n  .every(2, x => x.fast(2))\n// hi\nconst a = 1")
  check("translate", t == "_[#_ + 1] = s(\"bd\")\n  .every(2, function(x) return x.fast(2) end)\n--" ..
                      " hi\na = 1", t)
  check("translate strings", dsl.translate("s(\"a => b\")") == "s(\"a => b\")")
  check("translate backquote", dsl.translate("s(`a\nb`)") == "s([[a\nb]])")

  local function evalEvents(src, b, e)
    local r, err = dsl.eval(src)
    if not r then return "error: " .. tostring(err) end
    if not r.pattern then return "no pattern" end
    return events(r.pattern, b, e), r
  end
  same("eval expr", evalEvents('note("c e").s("saw")'), "note=48,s=saw@0-1/2 note=52,s=saw@1/2-1")
  same("eval colon", evalEvents('note("c e"):s("saw")'), "note=48,s=saw@0-1/2 note=52,s=saw@1/2-1")
  same("eval multiline", evalEvents('note("c e")\n  .fast(2)'),
       "note=48@0-1/4 note=52@1/4-1/2 note=48@1/2-3/4 note=52@3/4-1")
  local got, r = evalEvents('setcps(0.75)\ns("bd sd")')
  same("eval statements", got, "s=bd@0-1/2 s=sd@1/2-1")
  check("eval cps", r and r.cps == 0.75)
  same("eval $:", evalEvents('$: s("bd")\n$: s("hh hh")'), "s=bd@0-1 s=hh@0-1/2 s=hh@1/2-1")
  same("eval curried", evalEvents('s("a b").every(2, fast(2))', 1, 2), "s=a@1-3/2 s=b@3/2-2")
  same("eval rev fn", evalEvents('s("a b").every(1, rev)'), "s=b@0-1/2 s=a@1/2-1")
  same("eval arrow", evalEvents('note("c").off(0.5, x => x.add(7))'), "note=48@0-1 note=55@1/2-3/2")
  -- Backquotes holding "]]".
  same("eval backquote ]]", evalEvents("note(`<\n[e5 [b4 c5]]\n[c5 a4]\n>`)"),
       "note=76@0-1/2 note=71@1/2-3/4 note=72@3/4-1")

  -- JavaScript as Strudel files have it.
  local js = [==[
/* a block comment
   with (brackets] */
const mute = false;
let melody = `<
  [[E E] [- C]]
  [G -]
>`.add("12")
if (mute) {
  melody = melody.postgain(0)
} else {
  melody = melody.fast(1)
}
$: arrange(
  // first part
  [1, sqr(melody)._scope()],
  [2, sqr("c3")],
)
function sqr(x){
  if (mute) return note(x).gain(0);
  return note(x).s("square").clip("0.7").crush(4);
}
]==]
  local res, err = dsl.eval(js)
  check("js eval", res and res.pattern, err)
  if res and res.pattern then
    same("js cycle 0", events(res.pattern, 0, 1),
         "legato=0.7,note=64,s=square@0-1/4 legato=0.7,note=64,s=square@1/4-1/2 legato=0.7,note=60,s=square@3/4-1")
    same("js cycle 1", events(res.pattern, 1, 2), "legato=0.7,note=48,s=square@1-2")
    same("js cycle 3", events(res.pattern, 3, 4), "legato=0.7,note=67,s=square@3-7/2")
    check("js ignored", res.log[#res.log] == "Not on the sound card, ignored: crush", res.log[#res.log])
  end
  check("js if return", (dsl.translate("if (a) return b;")):find("if a then return b end", 1, true))
  check("js ops", dsl.translate("a === b && !c") == "a == b  and   not c", dsl.translate("a === b && !c"))
  check("lua if kept", dsl.translate("if (a) then b() end") == "if (a) then b() end")
  check("lua table key", dsl.translate("t = {[1] = 2}") == "t = {[1] = 2}")
  check("lua index", dsl.translate("x = t[1]") == "x = t[1]")
  check("string metatable restored", getmetatable("").__index == string)

  -- Envelopes as in Strudel: decay alone decays to nothing, release alone
  -- holds.
  check("adsr decay", C.render({s = "triangle", decay = 0.9}).sustain == 0)
  check("adsr release", C.render({s = "square", release = 0}).sustain == 15)
  check("adsr default", C.render({s = "square"}).sustain == 11)
  check("muted", C.render({s = "square", gain = 0}) == nil)

  check("eval error", not dsl.eval('note("c"'))
  check("eval runtime error", not dsl.eval('note("c").nope(1)'))
  for _, ex in ipairs(require "cycles.examples") do
    local res, err = dsl.eval(ex[2])
    check("example " .. ex[1], res and res.pattern, err)
    if res and res.pattern then
      local ok, e = pcall(res.pattern.query, span(0, frac(8)))
      check("example query " .. ex[1], ok, e)
      if ok then
        for _, h in ipairs(e) do
          if P.onset(h) and not C.render(h.value) then
            check("example render " .. ex[1], false, h.value.s)
            break
          end
        end
      end
    end
  end
end

-- ------------------------------------------------------------------- player
do
  local clock = 1000
  local sent = {}
  local fake = {
    at = function(t, op, ...) sent[#sent + 1] = {t = t, op = op, args = {...}} return true end,
    clear = function() end,
    off = function() end,
  }
  local pl = Player.new(fake, function() return clock end)
  pl:setPattern(dsl.eval('s("bd*4")').pattern)
  for _ = 1, 400 do  -- 4 s at cps 0.5: 2 cycles, 8 kicks
    pl:tick()
    clock = clock + 10
  end
  local notes = {}
  for _, e in ipairs(sent) do
    if e.op == "note" then notes[#notes + 1] = e end
  end
  check("player count", #notes >= 8 and #notes <= 9, #notes)
  local evenly = true
  for i = 2, #notes do
    if math.abs(notes[i].t - notes[i - 1].t - 500) > 1 then evenly = false end
  end
  check("player timing", evenly)
  -- Cycle 0 starts 100 ms after play: time for the first query.
  check("player first", notes[1] and notes[1].t == 1100, notes[1] and notes[1].t)
  local voices = {}
  for _, e in ipairs(notes) do voices[e.args[1]] = true end
  -- Each kick is silent after 151 ms: the same voice serves them all.
  check("player voices", voices[1] and not voices[2])

  -- Tempo change keeps time going forward.
  sent = {}
  pl:setCps(1)
  for _ = 1, 100 do
    pl:tick()
    clock = clock + 10
  end
  notes = {}
  for _, e in ipairs(sent) do
    if e.op == "note" then notes[#notes + 1] = e end
  end
  local ok = #notes >= 3
  for i = 2, #notes do
    if math.abs(notes[i].t - notes[i - 1].t - 250) > 1 then ok = false end
  end
  check("player cps", ok, #notes)

  -- Hours later, times stay exact.
  local c = P.frac(7200 * 48 + 7, 48)
  local t = pl:msAt(c)
  check("player far", pl:cycleAt(t) == c or pl:cycleAt(t + 1) == c, tostring(pl:cycleAt(t)))
end

report(string.format("%d passed, %d failed", passed, failed))
return failed == 0
