-- EH2 yaw sign fix (v2 -- CORRECTED). Makes the heading loop a stable NEGATIVE-feedback loop.
--
-- Measured from the Flight #9 log (425+ cycles):
--   A = sign(yaw demand -> change in yawRate sensor) = +1   (demand & rate sensor agree; damping OK)
--   Q = sign(yawRate sensor -> change in heading sensor) = -1  (corr -0.996 -- heading reads BACKWARDS
--       relative to the actual rotation)
-- Loop stability needs A*kd>0 (damping) AND Q*A*kp>0 (stiffness). A*kd>0 is fine; Q*A*kp<0 is a
-- NEGATIVE SPRING -> the position loop amplifies any yaw (the "always-left" disturbance) into a spin.
-- FIX: flip signHeading so Q becomes +1 (positive spring, stable). Keep signYawRate at +1 (the
-- earlier v1 of this script wrongly set it to -1 -- that inverted the already-correct damping and
-- left the real bug untouched; this restores it).
--
-- Root: signHeading and signYawRate were each calibrated against physics independently and ended
-- up mutually inconsistent. Persistent fix (later) = teach calibrate.lua to cross-check them.
--   wget run https://raw.githubusercontent.com/maar-10/EasyHover2/main/tools/fix_yaw_sign.lua

package.path = "/?.lua;/?/init.lua;" .. package.path
local cfgspec = require("fcs.io.cfgspec")
local fsx = require("fcs.io.fsx")
local LEGACY = "/eh2_hw_config.tbl"

local cfg, existed = cfgspec.load("senscal", fsx.read)
if not existed then
  local body = fsx.read(LEGACY)
  local legacy = body and textutils.unserialise(body) or nil
  if type(legacy) == "table" then cfg = cfgspec.merge("senscal", cfgspec.splitLegacy(legacy).senscal)
  else print("No senscal or legacy config found -- run /calibrate first; nothing to patch."); return end
end
local oh, oy = cfg.signHeading, cfg.signYawRate
cfg.signHeading = -1
cfg.signYawRate = 1
cfg.compassSign = -1   -- keep the PFD tape sign (rawHeading*compassSign) consistent with signHeading
cfgspec.save("senscal", cfg, fsx.writeAtomic)
print(("signHeading: %s -> -1"):format(tostring(oh)))
print(("signYawRate: %s -> 1  (reverting the earlier wrong flip)"):format(tostring(oy)))
print("compassSign: -> -1  (PFD tape follows signHeading)")
print("Saved to " .. cfgspec.FILES.senscal .. ". Now launch:  hovertest")
