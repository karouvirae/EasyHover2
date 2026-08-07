local widget = require("ui.widget")
local M = {}

function M.resolve(hitTable, x, y)
  for _, entry in ipairs(hitTable) do
    if widget.button.hit(entry.rect, x, y) then return entry.id end
  end
  return nil
end

return M
