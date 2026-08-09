-- fcs/input/config.lua
-- Pilot input tunables. All rates per-SECOND; distances in blocks.
return {
  default = {
    headingRate    = 0.9,   -- rad/s heading slew while yaw held
    leadCapHeading = 0.35,  -- max heading lead ahead of current (rad, ~20 deg) => stops promptly on release
    climbRate      = 2.0,   -- blocks/s altitude slew while lift held  (was 0.8: too slow)
    leadCapVert    = 5.0,   -- max altitude lead above/below current (blocks)
    cruiseSpeed    = 2.5,   -- blocks/s translation setpoint ramp  (was 1.0: too slow)
    maxLead        = 6.0,   -- max horizontal lead (blocks) => caps speed
  },
}
