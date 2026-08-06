-- EH2 quick fix -- flip the yaw-rate sensor sign so the heading loop's rate-damping is CORRECT.
--
-- Flight #9 yaw runaway: the yawRate sensor read OPPOSITE to the actual heading change (heading
-- climbed +0.27 rad/s while yawRate reported -0.26). The heading controller damps with -kd*yawRate,
-- so an inverted yawRate turned that damping into POSITIVE feedback -> a slow, accelerating spin
-- (kd=0.7 is large). The yaw-rate and heading sensors were each calibrated against physics in
-- isolation but ended up mutually inconsistent, which the heading loop can't tolerate.
--
-- This patches the SAVED hardware config: bindings.signYawRate -> -1. Only affects yawRate (sway/
-- surge use their own sensor signs). One-time; run once, then `hovertest`.
--   wget run https://raw.githubusercontent.com/maar-10/EasyHover2/worktree-level-actuator/tools/fix_yaw_sign.lua

local P = "/eh2_hw_config.tbl"
if not fs.exists(P) then
  print("No " .. P .. " found -- run /calibrate first; there's nothing to patch.")
  return
end
local f = fs.open(P, "r"); local c = textutils.unserialise(f.readAll() or ""); f.close()
if type(c) ~= "table" then print("Config file unreadable; aborting (no change made).") return end
c.bindings = c.bindings or {}
local old = c.bindings.signYawRate
c.bindings.signYawRate = -1
local w = fs.open(P, "w"); w.write(textutils.serialise(c)); w.close()
print("signYawRate: " .. tostring(old) .. " -> -1  (saved to " .. P .. ")")
print("Now launch the test:  hovertest")
