-- fcs/input/config.lua
-- Pilot input tunables. All rates per-SECOND; distances in blocks.
return {
  default = {
    headingRate    = 1.2,   -- rad/s heading slew while yaw held
    leadCapHeading = 0.80,  -- max heading lead ahead of current (rad, ~46 deg). 0.35 was too slow (yaw peaked 0.12 of a 0.5 cap); still bounded so release stops promptly
    climbRate      = 3.5,   -- blocks/s altitude slew while lift held  (2.0 still too slow; heave had headroom to 0.85)
    leadCapVert    = 7.0,   -- max altitude lead above/below current (blocks)
    cruiseSpeed    = 4.0,   -- blocks/s translation setpoint ramp  (2.5 still too slow)
    maxLead        = 9.0,   -- max horizontal lead (blocks) => caps speed
  },
}
