-- tests/test_scheme_drone.lua
local Drone = require("fcs.schemes.drone")
-- Attitude/alt pass through; lateral forced to zero even with position error present.
local d = Drone.new({ hoverDuty = 0.26, alt = {}, pitch = {}, roll = {}, yaw = {}, sway = {}, surge = {} })
local sp = { pitch = 0.1, roll = -0.1, heading = 0, altitude = 5, swayPos = 10, surgePos = 10 }
local m  = { pitch = 0, roll = 0, heading = 0, altitude = 5, swayPos = 0, surgePos = 0,
            swayVel = 0, surgeVel = 0, yawRate = 0 }
local out = d:update(sp, m, 0.05, false, nil)
assert(out.sway == 0, "sway forced 0")
assert(out.surge == 0, "surge forced 0")
assert(out.pitch ~= nil and out.roll ~= nil, "attitude demands present")
assert(out.heave ~= nil, "heave present")
-- delegated pids exposed for comAuto ki scoping
assert(d.pitchPid ~= nil and d.rollPid ~= nil, "inner pids exposed")
