-- fcs/runtime/flight.lua
local Flight = {}
Flight.__index = Flight

function Flight.new(deps)
  return setmetatable({
    loop = deps.loop, pilot = deps.pilot,
    engaged = false, gndSafety = true, positionHold = false,
    fuelPump = false, flightMode = "NORMAL",
    _needReset = false, _loopHz = 0,
  }, Flight)
end

function Flight:handleCommand(cmd)
  local k = cmd and cmd.k
  if k == "gndSafety" then
    self.gndSafety = cmd.on and true or false; return true
  elseif k == "engage" then
    if self.gndSafety then return false end
    self.engaged = true; self._needReset = true; self.loop:arm(true); return true
  elseif k == "disengage" then
    self.engaged = false; self.positionHold = false
    self.pilot:setPositionHold(false); self.loop:arm(false); return true
  elseif k == "positionHold" then
    self.positionHold = cmd.on and true or false
    self.pilot:setPositionHold(self.positionHold); return true
  elseif k == "fuelPump" then
    self.fuelPump = cmd.on and true or false; return true
  elseif k == "clearDamped" then
    self.loop:clearDamped(); return true
  elseif k == "flightMode" then
    self.flightMode = cmd.id; return true
  end
  return false
end

function Flight:step(dt, held, meas)
  if self.engaged then
    if self._needReset then self.pilot:reset(meas); self._needReset = false end
    self.loop:setpoints(self.pilot:update(dt, held or {}, meas))
  end
  local r = self.loop:cycle(dt, meas)
  self.lastDiag = r   -- exposed for optional flight instrumentation (demands/duties)
  if dt > 0 then self._loopHz = 1 / dt end
  return self:snapshot(r, meas)
end

-- Base snapshot: flags + measurement passthrough. Fuel/thruster detail is added
-- by the runtime wiring (Task D3) which has the backend handle.
function Flight:snapshot(r, meas)
  local m = meas or {}
  return {
    engaged = self.engaged, gndSafety = self.gndSafety,
    positionHold = self.positionHold, fuelPump = self.fuelPump,
    mode = (r and r.mode) or self.loop:getMode(), flightMode = self.flightMode,
    altitude = m.altitude, vSpeed = m.vSpeed, heading = m.heading,
    yawRate = m.yawRate, swayPos = m.swayPos, surgePos = m.surgePos,
    onGround = m.onGround, loopHz = self._loopHz,
  }
end

return Flight
