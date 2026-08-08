-- Pure peripheral-binding proposal for the EasyHover 2 UI Suite.
-- Given a list of peripheral descriptors ({ name=, type=, methods={[m]=true} }),
-- propose which peripheral to bind for the relay and fuel roles. No peripheral
-- access here -- callers pass in descriptors gathered elsewhere.
local Fuel = require("ui.fuel")

local M = {}

function M.propose(descriptors)
  local relay = nil
  local fuelNames = {}

  for _, d in ipairs(descriptors) do
    if relay == nil and d.type == "redstone_relay" then
      relay = d.name
    end
    if #fuelNames < 2 and Fuel.kindOf(d.methods) ~= "unknown" then
      fuelNames[#fuelNames + 1] = d.name
    end
  end

  return {
    relay = relay,
    fuel = { pump = fuelNames[1], tank = fuelNames[2] },
  }
end

return M
