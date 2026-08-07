local M = { button = {}, gauge = {}, field = {}, panel = {} }

function M.button.hit(rect, x, y)
  return x >= rect.x and x < rect.x + rect.w
     and y >= rect.y and y < rect.y + rect.h
end

function M.gauge.fill(value, width)
  if value < 0 then value = 0 elseif value > 1 then value = 1 end
  return math.floor(value * width + 0.5)
end

function M.field.format(label, value, width)
  label, value = tostring(label), tostring(value)
  local pad = width - #label - #value
  if pad < 1 then
    -- truncate value from the left so the label stays readable
    local keep = math.max(0, width - #label - 1)
    value = value:sub(-keep)
    pad = width - #label - #value
    if pad < 0 then label = label:sub(1, width - #value); pad = 0 end
  end
  return label .. string.rep(" ", pad) .. value
end

function M.panel.frame(x, y, w, h, title)
  return { x = x, y = y, w = w, h = h, title = title }
end

return M
