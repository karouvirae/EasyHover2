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

-- ===== Flight-mode selector (Task 12; LDG/DRN added later; split from master modes Task 10) =====
-- PRECISION / MAN / CRUISE / LDG / DRN, driven purely by reported telemetry -- no optimistic UI.
-- M.MODES lists the selectable flight modes; M.modeActive(ctx, id) is true only when the LATEST
-- reported ctx.flightMode equals id (ctx==nil/{} means nothing is active yet -- no optimism).
-- CPL/DCPL are a SEPARATE exclusive group -- see M.MASTERS below -- since a craft can be, e.g.,
-- CRUISE+CPL simultaneously (flight mode and master/coupling mode are independent axes).
M.MODES = { "PRECISION", "MAN", "CRUISE", "LDG", "DRN" }

-- Short ASCII display labels (CC:T font, no unicode) for the narrow selector surfaces -- the
-- merged region's ~14-col width can't fit the full mode ids side-by-side once there are 5 of them.
M.MODE_LABEL = { PRECISION = "PRE", MAN = "MAN", CRUISE = "CRU", LDG = "LDG", DRN = "DRN" }

local MODE_SET = {}
for _, id in ipairs(M.MODES) do MODE_SET[id] = true end

function M.modeActive(ctx, id)
  return (ctx and ctx.flightMode) == id
end

-- ===== Master (coupling) selector -- Task 10 =====
-- CPL / DCPL, a second exclusive group independent of the flight-mode selector above.
-- M.masterActive(ctx, id) is true only when the LATEST reported ctx.masterMode equals id.
M.MASTERS = { "CPL", "DCPL" }
M.MASTER_LABEL = { CPL = "CPL", DCPL = "DCPL" }

local MASTER_SET = {}
for _, id in ipairs(M.MASTERS) do MASTER_SET[id] = true end

function M.masterActive(ctx, id)
  return (ctx and ctx.masterMode) == id
end

-- ===== action(id, ctx) -> effect|nil =====
--
-- Mode ids (PRECISION/MAN/CRUISE) return the RAW flightMode command { k = "flightMode", id = id }
-- directly -- no ctx needed, matching fcs.runtime.flight's handleCommand shape (see
-- tests/test_flight_modes.lua) and tests/test_panels_fcs_modes.lua's F.action("MAN").k contract.
-- Every other (button) id keeps the pre-existing { kind = "command", cmd = ... } wrapped shape.
-- ui/basalt/pages/fcs.lua's M._onButton unwraps whichever shape comes back before sending.
function M.action(id, ctx)
  if MODE_SET[id] then
    return { k = "flightMode", id = id }
  end
  if MASTER_SET[id] then
    return { k = "masterMode", id = id }
  end

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
  elseif id == "trimUp" then
    return { kind = "command", cmd = { k = "flightTrim", dir = 1 } }
  elseif id == "trimDn" then
    return { kind = "command", cmd = { k = "flightTrim", dir = -1 } }
  end
  return nil
end

-- ===== Live auto-trim child button (CPL/DCPL only) =====
-- No-optimistic-UI: label/active state are driven purely by the reported ctx.trimDir/flightMode,
-- never by the tap itself -- mirrors M.modeActive's contract above.
function M.trimLabel(ctx)
  return ((ctx and ctx.trimDir and ctx.trimDir > 0) and "TRIM UP") or "TRIM DN"
end

function M.trimActive(ctx)  -- trim is a master-mode capability; a master is always set once telemetry arrives
  return ctx and (ctx.masterMode == "CPL" or ctx.masterMode == "DCPL")
end

-- ===== Exports for the Basalt cockpit page (ui/basalt/pages/fcs.lua) =====
-- Same reuse approach as ui/panels/engine.lua's buttonStates/fmt did for Task 15's EMC page:
-- expose the local helpers verbatim (no behavior change) so the page can drive its Labels/Button
-- styling from the SAME logic this panel's own render() uses, instead of re-deriving it.
M.buttonStates = buttonStates
M.fieldValues = fieldValues
M.fmt = fmt

return M
