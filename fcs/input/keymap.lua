-- fcs/input/keymap.lua
local M = {}

-- axis+dir -> held flag name
local FLAG = {
  yaw   = { [-1] = "yawLeft",  [1] = "yawRight" },
  lift  = { [-1] = "down",     [1] = "up" },
  sway  = { [-1] = "swayLeft", [1] = "swayRight" },
  surge = { [-1] = "surgeBack",[1] = "surgeFwd" },
}

function M.resolve(map, codes)
  local held = {}
  for _, code in ipairs(codes) do
    local m = map[code]
    if m then
      local flag = FLAG[m.axis] and FLAG[m.axis][m.dir]
      if flag then held[flag] = true end
    end
  end
  return held
end

-- Default typewriter layout (WASD move, QE yaw, R/Space up, F/LShift down). keys.* provided by CC.
M.default = {
  [keys.w] = {axis="surge", dir=1},  [keys.s] = {axis="surge", dir=-1},
  [keys.a] = {axis="sway",  dir=-1}, [keys.d] = {axis="sway",  dir=1},
  [keys.q] = {axis="yaw",   dir=-1}, [keys.e] = {axis="yaw",   dir=1},
  [keys.r] = {axis="lift",  dir=1},  [keys.f] = {axis="lift",  dir=-1},
  [keys.space]     = {axis="lift", dir=1},   -- climb  (alias for R)
  [keys.leftShift] = {axis="lift", dir=-1},  -- descend (alias for F)
}

return M
