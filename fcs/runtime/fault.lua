-- Device-fault pcall helper: keep the control task alive on a bad sensor/step, but NEVER swallow
-- CC:Tweaked's "Terminated" (Ctrl+T / bios.lua os.pullEvent). Design §11.9.
local M = {}

function M.orReraise(err)
  if err == "Terminated" then error(err, 0) end
  return tostring(err)
end

return M
