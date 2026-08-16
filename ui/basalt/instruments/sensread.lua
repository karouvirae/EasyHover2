-- ui/basalt/instruments/sensread.lua
-- PURE calibration applier for the PFD's local sensor reads. No Basalt/peripheral/fs/os. Mirrors
-- fcs/io/backend.lua:35-47 (copied, NOT refactored -- the FCS flight stack stays frozen): raw gimbal
-- angles + a cal table -> pitch/roll; raw medial velocity + cal -> sas (surge). All cal keys are
-- optional and `or`-defaulted exactly as backend.lua does, so a partial/absent cal never errors.
local M = {}

function M.attitude(angles, cal)
  cal = cal or {}
  if type(angles) ~= "table" then angles = {} end
  local gScale = cal.gimbalScale or 1
  local pitch = (cal.signPitch or 1) * gScale * (angles[cal.gimbalPitchIdx or 1] or 0)
  local roll  = (cal.signRoll  or 1) * gScale * (angles[cal.gimbalRollIdx  or 2] or 0)
  return pitch, roll
end

function M.surge(vel, cal)
  cal = cal or {}
  return (cal.signVelMedial or 1) * (type(vel) == "number" and vel or 0)
end

return M
