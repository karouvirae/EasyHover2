-- ui/cockpit.lua
local widget = require("ui.widget")
local M = {}

-- Static button layout. Rects are monitor cells; keep them apart so touches
-- resolve unambiguously. Column 1 = FCS actions, column 2 = toggles.
local BUTTONS = {
  { id = "engage",       rect = { x = 1,  y = 1,  w = 12, h = 3 }, label = "ENGAGE" },
  { id = "disengage",    rect = { x = 1,  y = 4,  w = 12, h = 3 }, label = "DISENGAGE" },
  { id = "clearDamped",  rect = { x = 1,  y = 7,  w = 12, h = 3 }, label = "CLR DAMP" },
  { id = "gndSafety",    rect = { x = 14, y = 1,  w = 12, h = 3 }, label = "GND SAFE" },
  { id = "positionHold", rect = { x = 14, y = 4,  w = 12, h = 3 }, label = "POS HOLD" },
  { id = "fuelPump",     rect = { x = 14, y = 7,  w = 12, h = 3 }, label = "FUEL PUMP" },
}

function M.buttons() return BUTTONS end

local function fmt(n, dp)
  if type(n) ~= "number" then return "--" end
  return string.format("%." .. (dp or 1) .. "f", n)
end

function M.render(snapshot)
  local s = snapshot or {}
  local buttons = {
    engage       = s.engaged and "active" or "idle",
    disengage    = s.engaged and "idle" or "active",
    clearDamped  = (s.mode == "DAMPED") and "active" or "idle",
    gndSafety    = s.gndSafety and "on" or "off",
    positionHold = s.positionHold and "on" or "off",
    fuelPump     = s.fuelPump and "on" or "off",
  }
  local fields = {
    widget.field.format("MODE", tostring(s.mode or "--"), 24),
    widget.field.format("ALT",  fmt(s.altitude), 24),
    widget.field.format("VSPD", fmt(s.vSpeed, 2), 24),
    widget.field.format("HDG",  fmt(s.heading, 3), 24),
    widget.field.format("LOOP", fmt(s.loopHz, 0) .. "Hz", 24),
    widget.field.format("LINK", s.linkUp and "UP" or "DOWN", 24),
  }
  local gauges = { { label = "FUEL", fill = s.fuelMain or 0 } }
  for i, f in ipairs(s.thrusterFuel or {}) do
    gauges[#gauges + 1] = { label = "T" .. i, fill = f }
  end
  return { fields = fields, gauges = gauges, buttons = buttons }
end

function M.command(id, snapshot)
  local s = snapshot or {}
  if id == "engage" then return { k = "engage" }
  elseif id == "disengage" then return { k = "disengage" }
  elseif id == "clearDamped" then return { k = "clearDamped" }
  elseif id == "gndSafety" then return { k = "gndSafety", on = not s.gndSafety }
  elseif id == "positionHold" then return { k = "positionHold", on = not s.positionHold }
  elseif id == "fuelPump" then return { k = "fuelPump", on = not s.fuelPump }
  end
  return nil
end

return M
