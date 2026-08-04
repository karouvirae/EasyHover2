local M = {}
function M.step(sp, target, pos, dt, speed, maxLead)
  local maxStep = speed * (dt > 0 and dt or 0)
  local d = target - sp
  if d > maxStep then sp = sp + maxStep
  elseif d < -maxStep then sp = sp - maxStep
  else sp = target end
  if sp > pos + maxLead then sp = pos + maxLead
  elseif sp < pos - maxLead then sp = pos - maxLead end
  return sp
end
return M
