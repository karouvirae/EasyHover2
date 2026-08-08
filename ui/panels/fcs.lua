-- ui/panels/fcs.lua
-- Pure FCS panel: layout/render/action. No peripheral access.
-- ctx = telemetry snapshot: { engaged, gndSafety, positionHold, mode, altitude, vSpeed, heading, loopHz, linkUp }
-- Lua 5.1 / CC:Tweaked.

local toolkit = require("ui.toolkit")

local M = {}
M.id = "fcs"
M.title = "FCS"

-- Default canvas used internally by render() (which doesn't receive w,h).
local DEFAULT_W, DEFAULT_H = 51, 19

local BUTTON_ORDER = { "engage", "disengage", "gndSafety", "positionHold", "clearDamped" }
local BUTTON_LABEL = {
  engage       = "ENGAGE",
  disengage    = "DISENGAGE",
  gndSafety    = "GND SAFE",
  positionHold = "POS HOLD",
  clearDamped  = "CLR DAMP",
}

local FIELDS = { "MODE", "ALT", "VSPD", "HDG", "LOOP", "LINK" }

-- ===== layout(w,h) -> { buttons = {...}, regions = { status = rect } } =====

function M.layout(w, h)
  w = w or DEFAULT_W
  h = h or DEFAULT_H

  local btnX, btnY = 2, 2
  local btnW, gap = 14, 1

  -- Button height adapts to h so all 5 controls + gaps always fit within the
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

  local statusX = btnX + btnW + 2
  local statusW = math.max(1, w - statusX - 1)
  local statusY = 2
  local statusH = math.max(1, h - statusY - 1)

  return {
    buttons = buttons,
    regions = {
      status = { x = statusX, y = statusY, w = statusW, h = statusH },
    },
  }
end

-- ===== render(ctx) -> drawlist =====

local function fmt(n, dp)
  if type(n) ~= "number" then return "--" end
  return string.format("%." .. (dp or 1) .. "f", n)
end

local function buttonStates(ctx)
  return {
    engage       = ctx.engaged and "active" or (ctx.gndSafety and "disabled" or "idle"),
    disengage    = (not ctx.engaged) and "active" or "idle",
    gndSafety    = ctx.gndSafety and "on" or "off",
    positionHold = ctx.positionHold and "on" or "off",
    clearDamped  = (ctx.mode == "DAMPED") and "active" or "idle",
  }
end

local function fieldValues(ctx)
  return {
    MODE = tostring(ctx.mode or "--"),
    ALT  = fmt(ctx.altitude),
    VSPD = fmt(ctx.vSpeed, 2),
    HDG  = fmt(ctx.heading, 0),
    LOOP = fmt(ctx.loopHz, 0) .. "Hz",
    LINK = ctx.linkUp and "UP" or "DOWN",
  }
end

function M.render(ctx, w, h)
  ctx = ctx or {}
  w = w or DEFAULT_W
  h = h or DEFAULT_H
  local lay = M.layout(w, h)
  local states = buttonStates(ctx)
  local values = fieldValues(ctx)

  local dl = {}
  dl[#dl + 1] = toolkit.frame(1, 1, w, h, M.title)

  for _, b in ipairs(lay.buttons) do
    dl[#dl + 1] = toolkit.button(b.id, b.rect.x, b.rect.y, b.rect.w, b.rect.h, b.label, states[b.id])
  end

  local st = lay.regions.status
  for i, name in ipairs(FIELDS) do
    local line = toolkit.fieldRow(name, values[name], st.w)
    dl[#dl + 1] = toolkit.text(st.x, st.y + i - 1, line)
  end

  return dl
end

-- ===== action(id, ctx) -> effect|nil =====

function M.action(id, ctx)
  ctx = ctx or {}
  if id == "engage" then
    if ctx.gndSafety then return nil end
    return { kind = "command", cmd = { k = "engage" } }
  elseif id == "disengage" then
    return { kind = "command", cmd = { k = "disengage" } }
  elseif id == "gndSafety" then
    return { kind = "command", cmd = { k = "gndSafety", on = not ctx.gndSafety } }
  elseif id == "positionHold" then
    return { kind = "command", cmd = { k = "positionHold", on = not ctx.positionHold } }
  elseif id == "clearDamped" then
    return { kind = "command", cmd = { k = "clearDamped" } }
  end
  return nil
end

return M
