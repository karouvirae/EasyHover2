-- ui/panels/config.lua
-- Pure Config panel: layout/render/action. No peripheral access, no config mutation.
-- ctx = { config=<UI config table>, monitors={<name>...}, detected=<Detect.propose result>|nil }
-- Lua 5.1 / CC:Tweaked.

local toolkit = require("ui.toolkit")

local M = {}
M.id = "config"
M.title = "CONFIG"

-- Default canvas used internally by render() (which doesn't receive w,h).
local DEFAULT_W, DEFAULT_H = 51, 19

local BIND_BUTTONS = { "bindRelay", "bindPump", "bindTank" }
local BIND_LABEL = {
  bindRelay = "BIND RELAY",
  bindPump  = "BIND PUMP",
  bindTank  = "BIND TANK",
}

local AUTO_BUTTONS = {
  "scan", "calFuel", "pulseUp", "pulseDn", "intervalUp", "intervalDn", "toggleInvert", "toggleKick",
}
local AUTO_LABEL = {
  scan         = "SCAN",
  calFuel      = "CAL FUEL",
  pulseUp      = "PULSE +50",
  pulseDn      = "PULSE -50",
  intervalUp   = "INTERVAL +100",
  intervalDn   = "INTERVAL -100",
  toggleInvert = "TOGGLE INVERT",
  toggleKick   = "TOGGLE KICK",
}

-- ===== layout(w,h,monitors) -> { buttons = {...}, headers = {...}, regions = {} } =====
-- monitors is an optional list of monitor names; per-monitor "assign:<name>" buttons are
-- built here (rects only -- the current-panel label is filled in by render(), which is the
-- only place ctx.config is consulted).

function M.layout(w, h, monitors)
  w = w or DEFAULT_W
  h = h or DEFAULT_H
  monitors = monitors or {}

  local btnX = 2
  local btnW = math.max(1, w - btnX - 1)

  -- Ordered list of rows: headers (plain text) interleaved with buttons.
  local rows = {}
  rows[#rows + 1] = { kind = "header", text = "DEVICE BINDING" }
  for _, name in ipairs(monitors) do
    rows[#rows + 1] = { kind = "button", id = "assign:" .. name, monitorName = name }
  end
  for _, id in ipairs(BIND_BUTTONS) do
    rows[#rows + 1] = { kind = "button", id = id, label = BIND_LABEL[id] }
  end
  rows[#rows + 1] = { kind = "button", id = "relaySide" }
  rows[#rows + 1] = { kind = "header", text = "ENGINE/UI AUTO-DETECT" }
  for _, id in ipairs(AUTO_BUTTONS) do
    rows[#rows + 1] = { kind = "button", id = id, label = AUTO_LABEL[id] }
  end
  rows[#rows + 1] = { kind = "header", text = "FCS CALIBRATION" }
  rows[#rows + 1] = { kind = "button", id = "fcsCal", label = "FCS CAL (coming next)" }

  -- Row height adapts to h so the whole stack always fits within the interior
  -- rows (2 .. h-1, leaving the frame's top/bottom border rows free).
  local n = #rows
  local avail = h - 2
  if avail < n then avail = n end
  local rowH = math.floor(avail / n)
  if rowH < 1 then rowH = 1 end

  local buttons, headers = {}, {}
  local y = 2
  for _, r in ipairs(rows) do
    local rect = { x = btnX, y = y, w = btnW, h = rowH }
    if r.kind == "header" then
      headers[#headers + 1] = { text = r.text, rect = rect }
    else
      buttons[#buttons + 1] = { id = r.id, rect = rect, label = r.label, monitorName = r.monitorName }
    end
    y = y + rowH
  end

  return { buttons = buttons, headers = headers, regions = {} }
end

-- ===== render(ctx, w, h) -> drawlist =====

local function buttonState(id, monitorName, cfg)
  if monitorName then return "idle" end
  if id == "fcsCal" then return "disabled" end
  if id == "bindRelay" then return (cfg.relay and cfg.relay.name) and "on" or "off" end
  if id == "bindPump" then return (cfg.fuel and cfg.fuel.pump and cfg.fuel.pump.name) and "on" or "off" end
  if id == "bindTank" then return (cfg.fuel and cfg.fuel.tank and cfg.fuel.tank.name) and "on" or "off" end
  if id == "toggleInvert" then return (cfg.engine and cfg.engine.invert) and "on" or "off" end
  if id == "toggleKick" then return (cfg.engine and cfg.engine.kickstart) and "on" or "off" end
  return "idle"
end

function M.render(ctx, w, h)
  ctx = ctx or {}
  w = w or DEFAULT_W
  h = h or DEFAULT_H
  local cfg = ctx.config or {}
  local assign = cfg.assign or {}
  local lay = M.layout(w, h, ctx.monitors)

  local dl = {}
  dl[#dl + 1] = toolkit.frame(1, 1, w, h, M.title)

  for _, hd in ipairs(lay.headers) do
    dl[#dl + 1] = toolkit.text(hd.rect.x, hd.rect.y, hd.text)
  end

  for _, b in ipairs(lay.buttons) do
    local label = b.label
    if b.monitorName then
      label = assign[b.monitorName] or "--"
    elseif b.id == "relaySide" then
      label = "RELAY SIDE: " .. ((cfg.relay and cfg.relay.side) or "back")
    end
    local state = buttonState(b.id, b.monitorName, cfg)
    dl[#dl + 1] = toolkit.button(b.id, b.rect.x, b.rect.y, b.rect.w, b.rect.h, label, state)
  end

  return dl
end

-- ===== action(id, ctx) -> effect|nil =====
-- Returns config-edit intents wrapped {kind="config", ...}; never mutates ctx.config.
-- fcsCal is a disabled placeholder (returns nil).

function M.action(id, ctx)
  if id:sub(1, 7) == "assign:" then
    return { kind = "config", op = "cycleAssign", monitor = id:sub(8) }
  elseif id == "scan" then
    return { kind = "config", op = "scan" }
  elseif id == "calFuel" then
    return { kind = "config", op = "calFuel" }
  elseif id == "pulseUp" then
    return { kind = "config", op = "stepEngine", field = "pulseMs", delta = 50 }
  elseif id == "pulseDn" then
    return { kind = "config", op = "stepEngine", field = "pulseMs", delta = -50 }
  elseif id == "intervalUp" then
    return { kind = "config", op = "stepEngine", field = "intervalMs", delta = 100 }
  elseif id == "intervalDn" then
    return { kind = "config", op = "stepEngine", field = "intervalMs", delta = -100 }
  elseif id == "toggleInvert" then
    return { kind = "config", op = "toggle", field = "invert" }
  elseif id == "toggleKick" then
    return { kind = "config", op = "toggle", field = "kickstart" }
  elseif id == "bindRelay" then
    return { kind = "config", op = "bind", role = "relay" }
  elseif id == "bindPump" then
    return { kind = "config", op = "bind", role = "pump" }
  elseif id == "bindTank" then
    return { kind = "config", op = "bind", role = "tank" }
  elseif id == "relaySide" then
    return { kind = "config", op = "cycleRelaySide" }
  end
  return nil
end

return M
