-- ui/panels/engine.lua
-- Pure Engine panel: layout/render/action. No peripheral access.
-- ctx = { pumpFrac(0..1), tankFrac(0..1), engine = { master, feeding, pulses, nextFeedInMs }, relayBound(bool) }
-- Lua 5.1 / CC:Tweaked.

local toolkit = require("ui.toolkit")

local M = {}
M.id = "engine"
M.title = "ENGINE"

-- Default canvas used internally by render() (which doesn't receive w,h).
local DEFAULT_W, DEFAULT_H = 51, 19

local BUTTON_ORDER = { "engineOn", "engineOff", "prime" }
local BUTTON_LABEL = {
  engineOn  = "ENGINE ON",
  engineOff = "ENGINE OFF",
  prime     = "PRIME",
}

-- ===== layout(w,h) -> { buttons = {...}, regions = { pump, tank, status = rect } } =====

function M.layout(w, h)
  w = w or DEFAULT_W
  h = h or DEFAULT_H

  local btnX, btnY = 2, 2
  local btnW, gap = 14, 1

  -- Button height adapts to h so all 3 controls + gaps always fit within the
  -- interior rows (2 .. h-1, leaving the frame's top/bottom border rows free).
  local rows = #BUTTON_ORDER
  local avail = h - 2
  if avail < rows then avail = rows end
  local btnH = math.floor((avail - (rows - 1) * gap) / rows)
  if btnH < 1 then btnH = 1 end

  local buttons = {}
  local y = btnY
  for _, id in ipairs(BUTTON_ORDER) do
    buttons[#buttons + 1] = {
      id = id,
      rect = { x = btnX, y = y, w = btnW, h = btnH },
      label = BUTTON_LABEL[id],
    }
    y = y + btnH + gap
  end

  local rightX = btnX + btnW + 2
  local rightW = math.max(1, w - rightX - 1)

  -- Gauges each take 2 screen rows (bar + label row painted by toolkit), stacked
  -- at the top of the right column; the status text fields fill the rest.
  local pumpY = 2
  local tankY = pumpY + 2
  local statusY = tankY + 2
  if statusY > h - 1 then statusY = math.max(pumpY, h - 1) end
  local statusH = math.max(1, h - statusY - 1)

  return {
    buttons = buttons,
    regions = {
      pump = { x = rightX, y = pumpY, w = rightW, h = 1 },
      tank = { x = rightX, y = tankY, w = rightW, h = 1 },
      status = { x = rightX, y = statusY, w = rightW, h = statusH },
    },
  }
end

-- ===== render(ctx, w, h) -> drawlist =====

local function buttonStates(ctx)
  if not ctx.relayBound then
    return { engineOn = "disabled", engineOff = "disabled", prime = "disabled" }
  end
  local eng = ctx.engine or {}
  return {
    engineOn  = eng.master and "active" or "idle",
    engineOff = (not eng.master) and "active" or "idle",
    prime     = eng.master and "idle" or "disabled",
  }
end

local function fmtMs(n)
  if type(n) ~= "number" then return "--" end
  return tostring(math.floor(n)) .. "ms"
end

local function statusLines(ctx, width)
  local eng = ctx.engine or {}
  local lines = {}
  lines[#lines + 1] = toolkit.fieldRow("MASTER", eng.master and "ON" or "OFF", width)
  lines[#lines + 1] = toolkit.fieldRow("FEED", eng.feeding and "FEEDING" or "idle", width)
  lines[#lines + 1] = toolkit.fieldRow("NEXT", fmtMs(eng.nextFeedInMs), width)
  lines[#lines + 1] = toolkit.fieldRow("PULSES", tostring(eng.pulses or 0), width)
  if ctx.relayBound then
    lines[#lines + 1] = toolkit.fieldRow("RELAY", "bound", width)
  else
    lines[#lines + 1] = toolkit.fieldRow("RELAY", "unbound", width)
    lines[#lines + 1] = ("bind relay in Config"):sub(1, width)
  end
  return lines
end

function M.render(ctx, w, h)
  ctx = ctx or {}
  w = w or DEFAULT_W
  h = h or DEFAULT_H
  local lay = M.layout(w, h)
  local states = buttonStates(ctx)

  local dl = {}
  dl[#dl + 1] = toolkit.frame(1, 1, w, h, M.title)

  for _, b in ipairs(lay.buttons) do
    dl[#dl + 1] = toolkit.button(b.id, b.rect.x, b.rect.y, b.rect.w, b.rect.h, b.label, states[b.id])
  end

  local pr = lay.regions.pump
  dl[#dl + 1] = toolkit.gauge(pr.x, pr.y, pr.w, "PUMP", ctx.pumpFrac or 0)

  local tr = lay.regions.tank
  dl[#dl + 1] = toolkit.gauge(tr.x, tr.y, tr.w, "TANK", ctx.tankFrac or 0)

  local st = lay.regions.status
  local lines = statusLines(ctx, st.w)
  for i, line in ipairs(lines) do
    dl[#dl + 1] = toolkit.text(st.x, st.y + i - 1, line)
  end

  return dl
end

-- ===== action(id, ctx) -> effect|nil =====

function M.action(id, ctx)
  ctx = ctx or {}
  if not ctx.relayBound then return nil end
  if id == "engineOn" then
    return { kind = "engine", op = "on" }
  elseif id == "engineOff" then
    return { kind = "engine", op = "off" }
  elseif id == "prime" then
    return { kind = "engine", op = "prime" }
  end
  return nil
end

return M
