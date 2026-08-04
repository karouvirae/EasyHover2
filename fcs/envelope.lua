local M = {}
function M.clamp(demands, caps)
  local out = {}
  for k, v in pairs(demands) do
    local c = caps[k]
    if c and v > c then out[k] = c
    elseif c and v < -c then out[k] = -c
    else out[k] = v end
  end
  return out
end
return M
