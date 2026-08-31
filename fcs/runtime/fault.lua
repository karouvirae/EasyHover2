-- Device-fault pcall helper: keep the control task alive on a bad sensor/step, but NEVER swallow
-- CC:Tweaked's "Terminated" (Ctrl+T / bios.lua os.pullEvent). Design §11.9.
local M = {}

function M.orReraise(err)
  if err == "Terminated" then error(err, 0) end
  return tostring(err)
end

function M.protect(fn)
  local ok, err = pcall(fn)
  if not ok then return false, M.orReraise(err) end
  return true
end

return M
