-- tools/capture_precision_golden.lua  (run once, headless, to print the frozen baseline)
local Scheme = require("fcs.schemes.level_flight")
local Mixer  = require("fcs.mixer.level_flight")
local g = require("fcs.io.tuningdefaults").get().gains

local function schemeCfg(gn)
  return { hoverDuty = gn.hoverDuty, alt = gn.alt, pitch = gn.pitch, roll = gn.roll,
    yaw = gn.yaw, sway = gn.sway, surge = gn.surge, heaveMin = gn.heaveMin, heaveMax = gn.heaveMax }
end

-- Deterministic battery: varied errors, grounded + airborne. dt fixed at 0.05.
local BATTERY = {
  -- NOTE: sp.altitude has no "or 0" fallback in level_flight.lua (unlike pitch/roll/yaw/sway/surge),
  -- so an absent altitude setpoint errors on nil arithmetic in the alt PID. Case 1 sets altitude=0
  -- explicitly to keep its "zero everywhere" intent without touching the untouched scheme file.
  { sp = { altitude=0 }, m = { altitude=0, pitch=0, roll=0, heading=0, yawRate=0, swayPos=0, swayVel=0, surgePos=0, surgeVel=0, onGround=false } },
  { sp = { altitude=5 }, m = { altitude=2, pitch=0.05, roll=-0.03, heading=0.2, yawRate=0.1, swayPos=1, swayVel=0.2, surgePos=-1, surgeVel=-0.1, onGround=false } },
  { sp = { altitude=3, heading=1.0, swayPos=2, surgePos=2 }, m = { altitude=3, pitch=-0.1, roll=0.08, heading=0.5, yawRate=-0.2, swayPos=0, swayVel=-0.3, surgePos=0, surgeVel=0.4, onGround=false } },
  { sp = { altitude=1 }, m = { altitude=1, pitch=0, roll=0, heading=0, yawRate=0, swayPos=0, swayVel=0, surgePos=0, surgeVel=0, onGround=true } },
}

local scheme, mixer = Scheme.new(schemeCfg(g)), Mixer.new()
local out = {}
for i, c in ipairs(BATTERY) do
  scheme:reset()
  local duties = mixer:mix(scheme:update(c.sp, c.m, 0.05, c.m.onGround))
  local keys = {}
  for k in pairs(duties) do keys[#keys+1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts+1] = string.format("%s=%.9f", k, duties[k]) end
  out[#out+1] = string.format("[%d] %s", i, table.concat(parts, " "))
end
local fh = fs.open("/golden_out.txt", "w")
fh.write(table.concat(out, "\n")); fh.close()
