-- Module of the salut package: require "salut.greet" loads it from /pkg/salut/.
local M = {}

function M.message(name)
  return "Hello, " .. name .. "!"
end

return M
