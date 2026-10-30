-- salut [name]: says hello, with the help of the salut.greet module.
local greet = require "salut.greet"

print(greet.message(arg[1] or "TERMINA"))
