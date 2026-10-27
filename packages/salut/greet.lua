-- Module du package salut : require "salut.greet" le charge depuis /pkg/salut/.
local M = {}

function M.message(name)
  return "Bonjour, " .. name .. " !"
end

return M
