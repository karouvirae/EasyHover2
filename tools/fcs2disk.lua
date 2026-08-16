-- tools/fcs2disk.lua
-- STANDALONE FCS console tool (SuiteX-installed like tools/splitconfig.lua -- NOT a flight-app
-- change): dumps the FCS's 3 local split config files (eh2_devbind/senscal/tuning) onto a shared
-- networked disk so the UI PC's DTC can IMPORT ALL them. PURE core here (plan()); the in-game
-- run() below resolves the drive + writes and is not headless-tested. Filenames NEVER hardcoded --
-- always cfgspec.FILES[kind].
local cfgspec = require("fcs.io.cfgspec")

local M = {}

-- FCS kinds this tool dumps, in cfgspec order (uicfg is UI-only and not on the FCS).
M.KINDS = { "devbind", "senscal", "tuning" }

-- plan(existing) -> { action, kinds, missing, err? }.
-- existing = { present = {kind=bool}, mount = <string|nil> }.
function M.plan(existing)
  existing = existing or {}
  local present = existing.present or {}
  if existing.mount == nil then return { action = "no-mount", kinds = {}, missing = {} } end
  local kinds, missing = {}, {}
  for _, k in ipairs(M.KINDS) do
    if present[k] == true then kinds[#kinds + 1] = k else missing[#missing + 1] = k end
  end
  if #kinds == 0 then return { action = "abort", kinds = kinds, missing = missing, err = "no local FCS configs to dump" } end
  return { action = "write", kinds = kinds, missing = missing }
end

return M
