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
  if #label >= width then
    -- Label alone fills or exceeds the field: no room for a value.
    return label:sub(1, width)
  end
  local avail = width - #label - 1   -- chars available for the value (>= 0), reserving >=1 gap
  if avail <= 0 then
    value = ""
  elseif #value > avail then
    value = value:sub(-avail)        -- keep the rightmost `avail` chars (avail >= 1 here)
  end
  local pad = width - #label - #value
  return label .. string.rep(" ", pad) .. value
end

function M.panel.frame(x, y, w, h, title)
  return { x = x, y = y, w = w, h = h, title = title }
end

return M
