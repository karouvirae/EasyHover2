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

  local x = 2
  local iw = math.max(1, w - 2)   -- full interior width (inside the frame borders)

  -- SINGLE responsive column so nothing falls off a narrow (portrait) monitor:
  -- two gauges (each a bar row + a label/percent row) at the top, the three
  -- control buttons in the middle at full width, the status fields at the bottom.
  local pumpY = 2
  local tankY = 4
  local btnTop = 6

  local rows = #BUTTON_ORDER      -- 3
  -- Reserve up to 6 rows for the status block, but never starve the buttons of
  -- at least one row each.
  local statusWant = 6
  local statusTop = h - statusWant
  if statusTop < btnTop + rows then statusTop = btnTop + rows end
  local btnAreaH = statusTop - btnTop
  local btnH = math.floor(btnAreaH / rows)
  if btnH < 1 then btnH = 1 end

  local buttons = {}
  local y = btnTop
  for _, id in ipairs(BUTTON_ORDER) do
    buttons[#buttons + 1] = {
      id = id,
      rect = { x = x, y = y, w = iw, h = btnH },
      label = BUTTON_LABEL[id],
    }
    y = y + btnH
  end

  local statusY = y
  if statusY > h - 1 then statusY = math.max(btnTop, h - 1) end
  local statusH = math.max(1, (h - 1) - statusY + 1)

  return {
    buttons = buttons,
    regions = {
      pump = { x = x, y = pumpY, w = iw, h = 1 },
      tank = { x = x, y = tankY, w = iw, h = 1 },
      status = { x = x, y = statusY, w = iw, h = statusH },
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
M.buttonStates = buttonStates

-- The feed countdown is minutes-scale (interval ~5m30s), so show m:ss, not raw ms.
local function fmtCountdown(ms)
  if type(ms) ~= "number" then return "--" end
  local s = math.floor(ms / 1000 + 0.5)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
M.fmtCountdown = fmtCountdown

local function statusLines(ctx, width)
  local eng = ctx.engine or {}
  local lines = {}
  lines[#lines + 1] = toolkit.fieldRow("MASTER", eng.master and "ON" or "OFF", width)
  lines[#lines + 1] = toolkit.fieldRow("FEED", eng.feeding and "FEEDING" or "idle", width)
  lines[#lines + 1] = toolkit.fieldRow("NEXT", fmtCountdown(eng.nextFeedInMs), width)
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
