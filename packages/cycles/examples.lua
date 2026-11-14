-- cycles.examples: pieces to start from (F2 in the editor).
return {
  {"hello", [[
-- F5 (or Ctrl+Enter) plays the code, F6 stops.
-- Change a note, press F5 again: it plays the new version at once.
note("c e g b").s("square")
]]},
  {"beat", [[
setcps(0.5)
$: s("bd [~ bd] sd ~, hh*8")
$: note("<c2 c2 eb2 g1>").s("triangle").legato(0.8)
]]},
  {"arpeggio", [[
setcps(0.6)
$: n("0 2 4 <7 9> 4 2").scale("<C:minor A2:minor>")
     .s("sawtooth").decay(0.15).sustain(0).gain(0.8)
$: note("<c2 a1>").s("triangle").legato(0.9)
$: s("bd*2, [~ hh]*2")
]]},
  {"euclid", [[
-- (k,n): k notes spread over n steps
$: s("bd(3,8), hh(5,8,2)")
$: note("c3(3,8) eb3(5,8)").s("pulse")
     .every(4, x => x.fast(2))
]]},
  {"chords", [[
setcpm(20)
$: note("<[c3,eb3,g3] [ab2,c3,eb3] [bb2,d3,f3] [g2,b2,d3]>")
     .s("square").attack(0.05).release(0.3).gain(0.6)
$: note("<c2 ab1 bb1 g1>*2").s("triangle")
]]},
  {"random", [[
-- the same "random" notes every time: they depend on the cycle
n("0*8").add(irand(8)).scale("D:dorian").s("pulse")
  .sometimes(x => x.add(7)).degradeBy(0.2).decay(0.1).sustain(0)
]]},
}
