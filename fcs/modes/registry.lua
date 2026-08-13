-- fcs/modes/registry.lua -- builds all three selectable flight modes ONCE at boot. Each
-- descriptor carries a ready scheme/mixer/caps/feel and a pilot policy. Selection at runtime
-- is then just an O(1) swap of which descriptor is active -- no per-tick allocation.
local Level  = require("fcs.schemes.level_flight")
local Manual = require("fcs.schemes.manual")
local Cruise = require("fcs.schemes.cruise")
local Mixer  = require("fcs.mixer.level_flight")

local M = {}

local function schemeCfg(g)
  return { hoverDuty = g.hoverDuty, alt = g.alt, pitch = g.pitch, roll = g.roll,
    yaw = g.yaw, sway = g.sway, surge = g.surge, heaveMin = g.heaveMin, heaveMax = g.heaveMax }
end

local SPECS = {
  { id = "PRECISION", label = "PRECISION", ctor = Level,  policy = { tilt = false, surge = "position" } },
  { id = "MAN",       label = "MAN",       ctor = Manual, policy = { tilt = true,  surge = "position" } },
  { id = "CRUISE",    label = "CRUISE",    ctor = Cruise, policy = { tilt = false, surge = "throttle" } },
}

-- tuning is a dot-function object: tuning.forMode(id) (matches fcs.tuning.forMode).
function M.build(tuning)
  local mixer = Mixer.new()               -- airframe-invariant; one shared instance
  local order, byId = {}, {}
  for _, s in ipairs(SPECS) do
    local cfg = tuning.forMode(s.id)
    order[#order+1] = s.id
    byId[s.id] = { id = s.id, label = s.label, policy = s.policy,
      scheme = s.ctor.new(schemeCfg(cfg.gains)), mixer = mixer,
      caps = cfg.caps, feel = cfg.feel }
  end
  return { order = order, default = "PRECISION", byId = byId }
end

return M
