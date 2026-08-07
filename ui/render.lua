-- ui/render.lua
-- Thin draw sink: turns a cockpit render model into monitor writes. No logic.
local M = {}

local STATE_BG = { active = colors.green, on = colors.green, idle = colors.gray, off = colors.red }

function M.draw(mon, model, buttons)
  mon.setBackgroundColor(colors.black); mon.clear()
  -- buttons
  for _, b in ipairs(buttons) do
    local st = model.buttons[b.id] or "idle"
    mon.setBackgroundColor(STATE_BG[st] or colors.gray)
    mon.setTextColor(colors.white)
    for row = 0, b.rect.h - 1 do
      mon.setCursorPos(b.rect.x, b.rect.y + row); mon.write(string.rep(" ", b.rect.w))
    end
    mon.setCursorPos(b.rect.x + 1, b.rect.y + math.floor(b.rect.h / 2)); mon.write(b.label)
  end
  -- fields
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white)
  local fy = 11
  for _, line in ipairs(model.fields) do
    mon.setCursorPos(1, fy); mon.write(line); fy = fy + 1
  end
  -- gauges
  for _, g in ipairs(model.gauges) do
    mon.setCursorPos(1, fy); mon.setTextColor(colors.white); mon.write(g.label .. " ")
    local width = 16
    local filled = math.floor((g.fill < 0 and 0 or g.fill > 1 and 1 or g.fill) * width + 0.5)
    mon.setBackgroundColor(colors.green); mon.write(string.rep(" ", filled))
    mon.setBackgroundColor(colors.gray);  mon.write(string.rep(" ", width - filled))
    mon.setBackgroundColor(colors.black); fy = fy + 1
  end
end

return M
