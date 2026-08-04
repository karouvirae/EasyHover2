local M = {}
function M.wrap(x)
  local twoPi = 2 * math.pi
  x = x % twoPi                 -- [0, 2pi)
  if x > math.pi then x = x - twoPi end
  return x
end
return M
