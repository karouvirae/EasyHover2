local M = {}
function M.shim(periphs)
  return {
    getNames = function() local n={}; for k in pairs(periphs) do n[#n+1]=k end; table.sort(n); return n end,
    getType = function(name) return periphs[name] and periphs[name]._type or nil end,
    wrap = function(name) return periphs[name] end,
  }
end
-- Fakes mimic real CC wrapped peripherals: methods are PLAIN functions (NO self arg),
-- called as p.setPower(v) / p.getHeight(). Thruster state is mutated via closure over the table.
-- Real Create thrusters expose setPower(0..15) (NOT setThrust) + getCurrentThrustKN (confirmed in-game).
function M.thruster()
  local f = { thrust = 0, fuelledKN = 24, _type = "thruster" }
  f.setPower = function(v) f.thrust = v end
  f.getPower = function() return f.thrust end
  f.getCurrentThrustKN = function() return f.thrust > 0 and f.fuelledKN or 0 end
  return f
end
function M.gimbal(a)   return { _type="gimbal_sensor",    getAngles=function() return a end } end
function M.altitude(h) return { _type="altitude_sensor",  getHeight=function() return h end } end
function M.velocity(v) return { _type="velocity_sensor",  getVelocity=function() return v end } end
function M.optical(d)  return { _type="optical_sensor",   getDistance=function() return d end } end
function M.navtable(x) return { _type="navigation_table", getRelativeAngle=function() return x end } end
return M
