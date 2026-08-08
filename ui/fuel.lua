-- Fuel-source classification + fraction math for the EasyHover 2 UI Suite.
-- Pure: kindOf/fraction/read take plain values (or an injected reader) and
-- return values -- no peripheral access here. The sink that wraps a real
-- peripheral into a `reader` lives in ui/main.lua.
local M = {}

-- Classify a peripheral by its method set (methods = { [name]=true, ... }).
function M.kindOf(methods)
  if methods.getFuelAmountMb or methods.tanks then return "fluid" end
  if methods.list or methods.size then return "inventory" end
  return "unknown"
end

local function clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

-- reading = { amount=, capacity= }. cal = { empty=, full= } fallback.
function M.fraction(reading, cal)
  local capacity = reading.capacity
  if type(capacity) == "number" and capacity > 0 then
    return clamp01(reading.amount / capacity)
  end
  cal = cal or {}
  local empty, full = cal.empty, cal.full
  if type(empty) ~= "number" or type(full) ~= "number" or full <= empty then
    return 0
  end
  return clamp01((reading.amount - empty) / (full - empty))
end

-- reader() -> amount, capacity. Returns frac, raw amount.
function M.read(reader, kind, cal)
  local amount, capacity = reader()
  return M.fraction({ amount = amount, capacity = capacity }, cal or {}), amount
end

return M
