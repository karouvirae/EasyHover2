-- fcs/input/config.lua
-- Pilot input tunables. All rates per-SECOND; distances in blocks.
return {
  default = {
    headingRate    = 1.6,   -- rad/s heading slew while yaw held
    leadCapHeading = 0.50,  -- max heading lead ahead of current (rad, ~29 deg). TIGHTER than 0.80 to
                            -- cut overshoot; yaw stays fast via the higher yaw kp (see fcs/tuning.lua)
    climbRate      = 4.5,   -- blocks/s altitude slew while lift held  (was 3.5: a touch more)
    leadCapVert    = 8.0,   -- max altitude lead above/below current (blocks)
    -- Fore/aft (main engine) and lateral get SEPARATE speed + lead so forward can be MUCH faster:
    surgeSpeed     = 10.0,  -- blocks/s fore/aft ramp  (WAY more forward speed; main engine)
    surgeLead      = 20.0,  -- max fore/aft lead (blocks) => the cruise-speed cap
    swaySpeed      = 5.0,   -- blocks/s lateral ramp  (more than before, but subordinate to forward)
    swayLead       = 10.0,  -- max lateral lead (blocks)
  },
}
