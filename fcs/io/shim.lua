local M = {}
function M.getNames() return peripheral.getNames() end
function M.getType(name) return peripheral.getType(name) end
function M.wrap(name) return peripheral.wrap(name) end
return M
