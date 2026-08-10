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

-- Manual-max fraction: divide a raw amount by a MANUALLY set max, ignoring any device-reported
-- capacity. Used by the merged flight page (config.fuel.<role>.full is the max the pilot sets
-- under CAL FUEL). Returns 0 for a missing/non-positive max or a non-number amount.
function M.manualFrac(amount, max)
  if type(amount) ~= "number" or type(max) ~= "number" or max <= 0 then return 0 end
  return clamp01(amount / max)
end

return M
