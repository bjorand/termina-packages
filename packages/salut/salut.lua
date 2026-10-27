-- salut [nom] : salue, avec l'aide du module salut.greet.
local greet = require "salut.greet"

print(greet.message(arg[1] or "TERMINA"))
