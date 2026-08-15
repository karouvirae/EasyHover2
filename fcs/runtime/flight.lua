-- fcs/runtime/flight.lua
local Flight = {}
Flight.__index = Flight

-- Default trimDir at boot: the default mode's own feel.trimDir when the registry descriptor
-- carries one (real fcs.io.tuningdefaults-built feels do), else -1 (nose-down trim convention).
local function defaultTrimDir(reg)
  local d = reg and reg.byId and reg.default and reg.byId[reg.default]
  local t = d and d.feel and d.feel.trimDir
  return t or -1
end

function Flight.new(deps)
  return setmetatable({
    loop = deps.loop, pilot = deps.pilot, registry = deps.registry,
    moveEps = deps.moveEps or 0.5,   -- ground-idle motion gate (blocks/s)
    engaged = false, gndSafety = true, positionHold = false,
    fuelPump = false, flightMode = (deps.registry and deps.registry.default) or "PRECISION", parked = false,
    trimDir = defaultTrimDir(deps.registry),
    _needReset = false, _loopHz = 0,
  }, Flight)
end

function Flight:handleCommand(cmd)
  local k = cmd and cmd.k
  if k == "gndSafety" then
    self.gndSafety = cmd.on and true or false; return true
  elseif k == "engage" then
    if self.gndSafety then return false end
    -- Engage only marks intent; arming is decided every step by the ground-idle gate, so
    -- engaging while parked on the pad stays silent until the pilot commands a climb.
    self.engaged = true; self._needReset = true; return true
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
    local reg = self.registry
    local d = reg and reg.byId[cmd.id]
    if not d then return true end                 -- unknown id: stay on current mode
    self.loop:setActive(d)
    self.pilot:setMode(d.policy, d.feel)
    self.flightMode = cmd.id
    self.trimDir = (d.feel and d.feel.trimDir) or self.trimDir
    return true
  elseif k == "flightTrim" then
    local dir = (cmd.dir and cmd.dir < 0) and -1 or 1
    self.trimDir = dir
    if self.pilot.setTrimDir then self.pilot:setTrimDir(dir) end
    return true
  end
  return false
end

-- Ground-idle predicate: the FCS is "parked" (engaged but should output ZERO thrust) only when it
-- sits still on the ground with no climb intent. Requiring at-rest as well as onGround defends the
-- fly-low-over-terrain case: a MOVING craft (onGround can flicker true over a tree/hill) is treated
-- as in-flight so the controller stays live. Isolated on purpose -- the next hardening (fuse baro /
-- altitude-vs-liftoff for uneven ground) is a one-function change here.
function Flight:_parked(held, meas)
  if not (meas and meas.onGround == true) then return false end
  if held and held.up == true then return false end        -- climb un-parks (liftoff)
  local eps = self.moveEps
  return math.abs(meas.vSpeed or 0) < eps
     and math.abs(meas.swayVel or 0) < eps
     and math.abs(meas.surgeVel or 0) < eps                 -- moving => in-flight, not parked
end

function Flight:step(dt, held, meas)
  if self.engaged then
    if self._needReset then self.pilot:reset(meas); self._needReset = false end
    self.parked = self:_parked(held, meas)
    if self.parked then
      self.pilot:reset(meas)         -- hold setpoints at current (no ramp/windup while parked)
      self.loop:arm(false)           -- engaged-but-idle: disarmed loop = zero thrust, no osc/DAMPED
    else
      self.loop:setpoints(self.pilot:update(dt, held or {}, meas))
      self.loop:arm(true)
    end
  else
    self.parked = false
    self.loop:arm(false)
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
    positionHold = self.positionHold, fuelPump = self.fuelPump, parked = self.parked,
    mode = self.parked and "PARKED" or ((r and r.mode) or self.loop:getMode()),
    flightMode = self.flightMode,
    trimDir = self.trimDir,
    altitude = m.altitude, vSpeed = m.vSpeed, heading = m.heading,
    yawRate = m.yawRate, swayPos = m.swayPos, surgePos = m.surgePos,
    onGround = m.onGround, loopHz = self._loopHz,
  }
end

return Flight
