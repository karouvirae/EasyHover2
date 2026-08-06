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
--   wget run https://raw.githubusercontent.com/maar-10/EasyHover2/worktree-level-actuator/tools/fix_yaw_sign.lua

local P = "/eh2_hw_config.tbl"
if not fs.exists(P) then
  print("No " .. P .. " found -- run /calibrate first; there's nothing to patch.")
  return
end
local f = fs.open(P, "r"); local c = textutils.unserialise(f.readAll() or ""); f.close()
if type(c) ~= "table" then print("Config file unreadable; aborting (no change made).") return end
c.bindings = c.bindings or {}
local oh, oy = c.bindings.signHeading, c.bindings.signYawRate
c.bindings.signHeading = -1   -- deterministic target regardless of prior runs
c.bindings.signYawRate = 1
local w = fs.open(P, "w"); w.write(textutils.serialise(c)); w.close()
print(("signHeading: %s -> -1"):format(tostring(oh)))
print(("signYawRate: %s -> 1  (reverting the earlier wrong flip)"):format(tostring(oy)))
print("Saved. Now launch:  hovertest")
