-- fcs/input/config.lua
-- Pilot input tunables. All rates per-SECOND; distances in blocks.
return {
  default = {
    headingRate = 0.6,   -- rad/s heading slew while yaw held
    climbRate   = 0.8,   -- blocks/s altitude slew while lift held
    leadCapVert = 3.0,   -- max altitude lead above/below current (blocks)
    cruiseSpeed = 1.0,   -- blocks/s translation setpoint ramp
    maxLead     = 4.0,   -- max horizontal lead (blocks) => caps speed
  },
}
