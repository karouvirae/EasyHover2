-- ui/panels/config.lua
-- Pure Config panel: layout/render/action. No peripheral access, no config mutation.
-- ctx = { config=<UI config table>, monitors={<name>...}, detected=<Detect.propose result>|nil }
-- Lua 5.1 / CC:Tweaked.

local toolkit = require("ui.toolkit")

local M = {}
M.id = "config"
M.title = "CONFIG"

-- Default canvas used internally by render() (which may be called without w,h).
local DEFAULT_W, DEFAULT_H = 51, 19

-- Static labels for the fixed (non-dynamic) buttons. Dynamic labels (monitor
-- assigns, bind-with-name, relay side) are built in labelFor() from ctx.config.
local LABEL = {
  scan         = "SCAN",
  calFuel      = "CAL FUEL",
  pulseUp      = "PULSE +50",
  pulseDn      = "PULSE -50",
  intervalUp   = "INT +15s",
  intervalDn   = "INT -15s",
  toggleInvert = "INVERT",
  toggleKick   = "KICK",
  fcsCal       = "FCS CAL (soon)",
}

-- ===== layout(w,h,monitors) -> { buttons={...}, headers={...}, infos={...} } =====
-- Rows are compact (1 screen row each) and several controls share a row so the
-- whole panel fits a real monitor without cropping. Name-bearing buttons
-- (bind relay/pump/tank, relay side) get a full-width row; the dense controls
-- (monitor assigns, scan/cal, pulse +/-, interval +/-, toggles) pair up.

function M.layout(w, h, monitors)
  w = w or DEFAULT_W
  h = h or DEFAULT_H
  monitors = monitors or {}

  local x0 = 2
  local iw = math.max(1, w - 2)

  -- Build an ordered list of rows. Each row is one of:
  --   { header = <text> }               plain section header
  --   { info   = <kind> }               dynamic status text (rendered from ctx)
  --   { cells  = { {id=,monitorName=}, ... } }   1..N buttons sharing the row
  local rows = {}
  rows[#rows + 1] = { header = "DEVICE BINDING" }

  -- monitor assigns, two per row (short labels)
  local pair = {}
  for _, name in ipairs(monitors) do
    pair[#pair + 1] = { id = "assign:" .. name, monitorName = name }
    if #pair == 2 then rows[#rows + 1] = { cells = pair }; pair = {} end
  end
  if #pair > 0 then rows[#rows + 1] = { cells = pair } end

  rows[#rows + 1] = { cells = { { id = "bindRelay" } } }
  rows[#rows + 1] = { cells = { { id = "bindPump" } } }
  rows[#rows + 1] = { cells = { { id = "bindTank" } } }
  rows[#rows + 1] = { cells = { { id = "relaySide" } } }

  rows[#rows + 1] = { header = "ENGINE/UI AUTO-DETECT" }
  rows[#rows + 1] = { info = "timing" }
  rows[#rows + 1] = { cells = { { id = "scan" }, { id = "calFuel" } } }
  rows[#rows + 1] = { cells = { { id = "pulseDn" }, { id = "pulseUp" } } }
  rows[#rows + 1] = { cells = { { id = "intervalDn" }, { id = "intervalUp" } } }
  rows[#rows + 1] = { cells = { { id = "toggleInvert" }, { id = "toggleKick" } } }

  rows[#rows + 1] = { header = "FCS CALIBRATION" }
  rows[#rows + 1] = { cells = { { id = "fcsCal" } } }

  -- Row height: 1 by default (compact). If the monitor is tall, grow rows to
  -- fill; if short, stays 1 (extreme-small monitors can still clip the tail --
  -- a known limitation, deferred).
  local n = #rows
  local avail = h - 2
  if avail < n then avail = n end
  local rowH = math.floor(avail / n)
  if rowH < 1 then rowH = 1 end

  local out = { buttons = {}, headers = {}, infos = {} }
  local y = 2
  for _, r in ipairs(rows) do
    if r.header then
      out.headers[#out.headers + 1] = { text = r.header, x = x0, y = y }
    elseif r.info then
      out.infos[#out.infos + 1] = { kind = r.info, x = x0, y = y, w = iw }
    else
      local k = #r.cells
      local cellW = math.max(1, math.floor(iw / k))
      for i, c in ipairs(r.cells) do
        local bx = x0 + (i - 1) * cellW
        -- last cell absorbs any remainder; earlier cells leave a 1-col gutter
        local bw = (i == k) and (iw - (i - 1) * cellW) or (cellW - 1)
        out.buttons[#out.buttons + 1] = {
          id = c.id,
          monitorName = c.monitorName,
          rect = { x = bx, y = y, w = math.max(1, bw), h = rowH },
        }
      end
    end
    y = y + rowH
  end
  return out
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

local function shortName(n)
  if type(n) == "string" and n ~= "" then return n end
  return "--"
end

local function labelFor(b, cfg, assign)
  local id = b.id
  if b.monitorName then return assign[b.monitorName] or "--" end
  if id == "relaySide" then return "RELAY SIDE: " .. ((cfg.relay and cfg.relay.side) or "back") end
  if id == "bindRelay" then return "RELAY: " .. shortName(cfg.relay and cfg.relay.name) end
  if id == "bindPump" then return "PUMP: " .. shortName(cfg.fuel and cfg.fuel.pump and cfg.fuel.pump.name) end
  if id == "bindTank" then return "TANK: " .. shortName(cfg.fuel and cfg.fuel.tank and cfg.fuel.tank.name) end
  return LABEL[id] or id
end
M.labelFor = labelFor

-- Feed interval reads in minutes+seconds (it is minutes-scale on this build); pulse stays ms.
local function fmtInterval(ms)
  if type(ms) ~= "number" then return "?" end
  local totalSec = math.floor(ms / 1000 + 0.5)
  local m = math.floor(totalSec / 60)
  local s = totalSec % 60
  return string.format("%dm%02ds", m, s)
end
M.fmtInterval = fmtInterval

local function timingLine(cfg, width)
  local e = cfg.engine or {}
  local s = string.format("P %sms  I %s  inv %s  kick %s",
    tostring(e.pulseMs or "?"), fmtInterval(e.intervalMs),
    (e.invert and "on" or "off"), (e.kickstart and "on" or "off"))
  return s:sub(1, math.max(0, width))
end
M.timingLine = timingLine

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
    dl[#dl + 1] = toolkit.text(hd.x, hd.y, hd.text)
  end

  for _, inf in ipairs(lay.infos) do
    if inf.kind == "timing" then
      dl[#dl + 1] = toolkit.text(inf.x, inf.y, timingLine(cfg, inf.w))
    end
  end

  for _, b in ipairs(lay.buttons) do
    local label = labelFor(b, cfg, assign)
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
    return { kind = "config", op = "stepEngine", field = "intervalMs", delta = 15000 }
  elseif id == "intervalDn" then
    return { kind = "config", op = "stepEngine", field = "intervalMs", delta = -15000 }
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
