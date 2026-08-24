-- ui/basalt/instruments/readout.lua
-- PURE view-model: the ALT and SPD readouts for the PFD (lower-right). No Basalt/peripheral/fs/os.
-- GPS-derived sources (ALT/GPS, SPD/TAS) render only on a good fresh fix (state.gpsFixOk), else
-- "---" -- never a stale number. Baro/SAS always render their local value.
local M = {}

local function round(x) return math.floor(x + 0.5) end

-- num(value, needFix, fixOk) -> "<rounded>" or "---"
local function num(value, needFix, fixOk)
  if needFix and not fixOk then return "---" end
  if type(value) ~= "number" then return "---" end
  return tostring(round(value))
end

function M.alt(state)
  state = state or {}
  local src = state.altSource or "Baro"
  if src == "GPS" then
    return "ALT " .. num(state.gpsAlt, true, state.gpsFixOk) .. " GPS"
  end
  return "ALT " .. num(state.baroAlt, false, true) .. " Baro"
end

-- tgt(target) -> { line1, line2 } | nil. The PFD's waypoint steering readout: line1 the target name,
-- line2 the horizontal distance + altitude delta (climb/descend) + a steer arrow (< left / > right,
-- with a small deadband). target = { name, distanceH, relBearing, altDelta }. PURE.
function M.tgt(target)
  if type(target) ~= "table" then return nil end
  local dist = (type(target.distanceH) == "number") and (tostring(round(target.distanceH)) .. "m") or "--"
  local alt = ""
  if type(target.altDelta) == "number" then
    local a = round(target.altDelta)
    alt = (a >= 0 and "+" or "") .. tostring(a)
  end
  local arrow = ""
  if type(target.relBearing) == "number" then
    if target.relBearing > 2 then arrow = ">" elseif target.relBearing < -2 then arrow = "<" end
  end
  return { line1 = "TGT " .. tostring(target.name or "?"),
           line2 = (dist .. "  " .. alt .. "  " .. arrow) }
end

function M.spd(state)
  state = state or {}
  local src = state.spdSource or "SAS"
  if src == "TAS" then
    return "SPD " .. num(state.tas, true, state.gpsFixOk) .. " TAS"
  end
  return "SPD " .. num(state.sas, false, true) .. " SAS"
end

return M
