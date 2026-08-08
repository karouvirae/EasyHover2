-- ui/toolkit.lua
-- Pure layout/geometry helpers + draw-model builders + a paint sink.
-- Lua 5.1 / CC:Tweaked.

local M = {}

-- ===== Pure geometry (ported from ui/widget.lua, same math) =====

function M.hit(rect, x, y)
  return x >= rect.x and x < rect.x + rect.w
     and y >= rect.y and y < rect.y + rect.h
end

function M.gaugeFill(frac, width)
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  return math.floor(frac * width + 0.5)
end

function M.fieldRow(label, value, width)
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

-- ===== Draw-model builders (pure; return plain typed tables) =====

function M.button(id, x, y, w, h, label, state)
  return { kind = "button", id = id, rect = { x = x, y = y, w = w, h = h }, label = label, state = state }
end

function M.frame(x, y, w, h, title)
  return { kind = "frame", rect = { x = x, y = y, w = w, h = h }, title = title }
end

function M.gauge(x, y, w, label, frac)
  return { kind = "gauge", rect = { x = x, y = y, w = w, h = 1 }, label = label, frac = frac }
end

function M.text(x, y, s, color)
  return { kind = "text", x = x, y = y, s = s, color = color }
end

-- ===== Paint sink (NOT unit-tested; issues mon.* draw calls only) =====

-- on/active -> green, off -> red, idle -> gray fill; disabled has no fill
-- (stays background-colored) and is marked by darkGray (colors.gray) text instead.
local BUTTON_BG = {
  on = colors.green,
  active = colors.green,
  off = colors.red,
  idle = colors.gray,
}

local function drawButton(mon, item)
  local r = item.rect
  local bg = BUTTON_BG[item.state] or colors.black
  mon.setBackgroundColor(bg)
  if item.state == "disabled" then
    mon.setTextColor(colors.gray)
  else
    mon.setTextColor(colors.white)
  end
  for row = 0, r.h - 1 do
    mon.setCursorPos(r.x, r.y + row)
    mon.write(string.rep(" ", r.w))
  end
  local label = tostring(item.label or "")
  local lx = r.x + math.floor((r.w - #label) / 2)
  local ly = r.y + math.floor((r.h - 1) / 2)
  mon.setCursorPos(lx, ly)
  mon.write(label)
end

local function drawFrame(mon, item)
  local r = item.rect
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  -- top border
  mon.setCursorPos(r.x, r.y)
  mon.write("+" .. string.rep("-", r.w - 2) .. "+")
  -- side borders
  for row = 1, r.h - 2 do
    mon.setCursorPos(r.x, r.y + row)
    mon.write("|")
    mon.setCursorPos(r.x + r.w - 1, r.y + row)
    mon.write("|")
  end
  -- bottom border
  if r.h > 1 then
    mon.setCursorPos(r.x, r.y + r.h - 1)
    mon.write("+" .. string.rep("-", r.w - 2) .. "+")
  end
  -- title on the top row
  if item.title and item.title ~= "" then
    local title = " " .. tostring(item.title) .. " "
    mon.setCursorPos(r.x + 1, r.y)
    mon.write(title:sub(1, math.max(0, r.w - 2)))
  end
end

local function drawGauge(mon, item)
  local r = item.rect
  local filled = M.gaugeFill(item.frac, r.w)
  mon.setCursorPos(r.x, r.y)
  mon.setBackgroundColor(colors.green)
  mon.write(string.rep(" ", filled))
  mon.setBackgroundColor(colors.gray)
  mon.write(string.rep(" ", r.w - filled))
  if item.label and item.label ~= "" then
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.setCursorPos(r.x, r.y + 1)
    mon.write(tostring(item.label))
  end
end

local function drawText(mon, item)
  mon.setBackgroundColor(colors.black)
  if item.color then
    mon.setTextColor(item.color)
  end
  mon.setCursorPos(item.x, item.y)
  mon.write(tostring(item.s))
end

local PAINTERS = {
  button = drawButton,
  frame = drawFrame,
  gauge = drawGauge,
  text = drawText,
}

function M.paint(mon, drawlist)
  mon.setBackgroundColor(colors.black)
  mon.clear()
  for _, item in ipairs(drawlist) do
    local painter = PAINTERS[item.kind]
    if painter then painter(mon, item) end
  end
end

return M
