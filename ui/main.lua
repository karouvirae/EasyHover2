-- ui/main.lua
-- UI-PC multi-monitor cockpit runtime: receives telemetry, renders reported
-- state on N assigned monitors + the terminal (which always hosts the Config
-- panel), sends commands/engine ops/config edits on touch. This file is GLUE
-- ONLY -- every decision (layout, state machine, fraction math, binding
-- proposals, assignment resolution) lives in the pure ui/* modules it wires
-- together. Not unit-tested; verified by loadfile + manual/in-game smoke.
package.path = "/?.lua;/?/init.lua;" .. package.path

local Config   = require("ui.config")
local toolkit  = require("ui.toolkit")
local Engine   = require("ui.engine")
local Fuel     = require("ui.fuel")
local Detect   = require("ui.detect")
local Monitors = require("ui.monitors")

local FcsPanel    = require("ui.panels.fcs")
local EnginePanel = require("ui.panels.engine")
local ConfigPanel = require("ui.panels.config")

local modemlib  = require("fcs.comms.modem")
local telemetry = require("fcs.comms.telemetry")
local command   = require("fcs.comms.command")
local health    = require("fcs.comms.health")

local CONFIG_PATH = "/eh2_ui_config.tbl"
local config = Config.withDefaults(select(1, Config.load(CONFIG_PATH)) or {})

-- ===== Comms (reused verbatim from the previous ui/main.lua) =====

local CH = { telemetry = 101, command = 102, ack = 103, health = 104 }
local modem = peripheral.find("modem")
assert(modem, "UI-PC needs a modem on the wired network")

-- One link per logical channel (UI listens on telemetry/ack/health, sends on command).
local telLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.telemetry })
local ackLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.ack })
local hbLink  = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.health })
for _, c in pairs(CH) do modem.open(c) end

local rx = telemetry.Rx.new()
local sender = command.Sender.new({ timeout = 0.5 })
local hbRx = health.Rx.new({ timeout = 2.0 })

local function snapshot()
  local latest = rx:latest() or {}
  local s = {}
  for k, v in pairs(latest) do s[k] = v end
  s.linkUp = hbRx:up(os.epoch("utc") / 1000)
  return s
end

-- ===== Engine relay: dumb passthrough writer (ui/engine.lua owns ALL inversion) =====

local relay = nil
local function rebindRelay()
  relay = nil
  if config.relay.name and config.relay.side then
    local ok, p = pcall(peripheral.wrap, config.relay.name)
    if ok then relay = p end
  end
end
rebindRelay()

-- `signal` is the PHYSICAL relay level already computed by ui/engine.lua.
-- No `not`/inversion here -- this closure only ever forwards what it's given.
-- pcall-wrapped (matching EH1's engine.lua) so a disconnected/broken relay
-- throws here, not up through engine:tick into the shared parallel.waitForAny
-- -- an uncaught error there would kill render/touch/comms along with it.
-- engine:_write dedups on the physical signal via lastWritten, which this
-- function never touches on failure, so a failed write is retried next tick.
local function writer(signal)
  if not relay then return false end
  local ok = pcall(relay.setOutput, config.relay.side, signal)
  return ok
end

local engine = Engine.new(config.engine, writer)

-- ===== Fuel readers (sink over config.fuel.<role>; pure fraction math lives in ui/fuel.lua) =====

local function makeFuelReader(role)
  return function()
    local fc = config.fuel[role]
    if not fc or not fc.name then return 0, nil end
    local ok, p = pcall(peripheral.wrap, fc.name)
    if not ok or not p then return 0, nil end
    if fc.kind == "fluid" then
      if p.getFuelAmountMb then
        local ok1, amt = pcall(p.getFuelAmountMb)
        local cap = nil
        if p.getFuelCapacityMb then
          local ok2, c = pcall(p.getFuelCapacityMb)
          if ok2 then cap = c end
        end
        return (ok1 and amt) or 0, cap
      elseif p.tanks then
        local ok3, tanks = pcall(p.tanks)
        local t = ok3 and tanks and tanks[1]
        if t then return t.amount or 0, t.capacity end
        return 0, nil
      end
      return 0, nil
    else
      local amount = 0
      if p.list then
        local ok4, items = pcall(p.list)
        if ok4 and items then
          for _, item in pairs(items) do amount = amount + (item.count or 0) end
        end
      end
      local capacity = nil
      if p.size then
        local ok5, sz = pcall(p.size)
        if ok5 and sz then capacity = sz * 64 end
      end
      return amount, capacity
    end
  end
end

local fuelReaders = { pump = makeFuelReader("pump"), tank = makeFuelReader("tank") }

local state = {
  pumpFrac = 0,
  tankFrac = 0,
  detected = nil,   -- last Detect.propose result (+ raw descriptors), for the Config panel
}

-- ===== Monitor discovery + assignment resolution =====

local monitorNames = {}
local monByName = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "monitor" then
    monitorNames[#monitorNames + 1] = name
    monByName[name] = peripheral.wrap(name)
  end
end

local monitorsResolved = Monitors.resolve(config.assign, monitorNames)

-- Per-monitor hit tables, cached from the last Monitors.render() call --
-- touch hit-testing scans THESE (the drawlist's own button items), never a
-- separate panel.layout(...) call.
local hitCache = {}
local termHits = {}

local panels = { engine = EnginePanel, fcs = FcsPanel, config = ConfigPanel }

-- ===== ctx builders (live state -> the ctx shape each panel expects) =====

local function fcsCtx()
  return snapshot()
end

local function engineCtx(now)
  return {
    pumpFrac   = state.pumpFrac,
    tankFrac   = state.tankFrac,
    engine     = engine:status(now),
    relayBound = relay ~= nil,
  }
end

local function configCtx()
  return {
    config    = config,
    monitors  = monitorNames,
    detected  = state.detected,
  }
end

local function ctxFor(panelId, now)
  if panelId == "engine" then return engineCtx(now) end
  if panelId == "fcs" then return fcsCtx() end
  if panelId == "config" then return configCtx() end
  return {}
end

-- ===== Render (redraw sinks; no decisions) =====

local function renderMonitor(name, now)
  local mon = monByName[name]
  local panelId = monitorsResolved.assigned[name]
  if not panelId then
    toolkit.paint(mon, {})
    hitCache[name] = {}
    return
  end
  hitCache[name] = Monitors.render(mon, panels[panelId], ctxFor(panelId, now))
end

local function renderTerm(now)
  local w, h = term.getSize()
  local drawlist = ConfigPanel.render(configCtx(), w, h)
  toolkit.paint(term, drawlist)
  termHits = {}
  for _, item in ipairs(drawlist) do
    if item.kind == "button" then termHits[#termHits + 1] = item end
  end
end

local function redrawAll(now)
  for _, name in ipairs(monitorNames) do renderMonitor(name, now) end
  renderTerm(now)
end

local redrawPending = false
local function markDirty()
  if redrawPending then return end
  redrawPending = true
  os.queueEvent("eh2_redraw")
end

-- ===== Config-edit intents (pure decisions applied here; each edit -> Config.save) =====

local ASSIGN_CYCLE = { "engine", "fcs", "config" }
local function nextAssign(cur)
  if cur == nil then return ASSIGN_CYCLE[1] end
  for i, v in ipairs(ASSIGN_CYCLE) do
    if v == cur then
      if i == #ASSIGN_CYCLE then return nil end
      return ASSIGN_CYCLE[i + 1]
    end
  end
  return ASSIGN_CYCLE[1]
end

-- Descriptors for Detect.propose / manual bind candidates: { name, type, methods={[m]=true} }.
local function scanDescriptors()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    local ok, p = pcall(peripheral.wrap, name)
    local methods = {}
    if ok and p then
      for k, v in pairs(p) do
        if type(v) == "function" then methods[k] = true end
      end
    end
    out[#out + 1] = { name = name, type = peripheral.getType(name), methods = methods }
  end
  return out
end

local function kindOfName(descriptors, name)
  for _, d in ipairs(descriptors) do
    if d.name == name then return Fuel.kindOf(d.methods) end
  end
  return "inventory"
end

local function doScan()
  local descriptors = scanDescriptors()
  local proposal = Detect.propose(descriptors)
  state.detected = { descriptors = descriptors, proposal = proposal }

  if proposal.relay then
    config.relay.name = proposal.relay
    if not config.relay.side then config.relay.side = "back" end
    rebindRelay()
    engine:blockNow()
  end
  if proposal.fuel.pump then
    config.fuel.pump.name = proposal.fuel.pump
    config.fuel.pump.kind = kindOfName(descriptors, proposal.fuel.pump)
  end
  if proposal.fuel.tank then
    config.fuel.tank.name = proposal.fuel.tank
    config.fuel.tank.kind = kindOfName(descriptors, proposal.fuel.tank)
  end
end

-- role: "relay" | "pump" | "tank". Cycles through matching-type candidates
-- (simple approach per the brief: no persistent candidate list, just rescan
-- + advance past whatever's currently bound).
local function doBind(role)
  local descriptors = scanDescriptors()
  local candidates = {}
  if role == "relay" then
    for _, d in ipairs(descriptors) do
      if d.type == "redstone_relay" then candidates[#candidates + 1] = d.name end
    end
  else
    for _, d in ipairs(descriptors) do
      if Fuel.kindOf(d.methods) ~= "unknown" then candidates[#candidates + 1] = d.name end
    end
  end
  if #candidates == 0 then return end

  local current = (role == "relay") and config.relay.name or config.fuel[role].name
  local idx = 0
  for i, n in ipairs(candidates) do
    if n == current then idx = i break end
  end
  local picked = candidates[(idx % #candidates) + 1]

  if role == "relay" then
    config.relay.name = picked
    if not config.relay.side then config.relay.side = "back" end
    rebindRelay()
    engine:blockNow()
  else
    config.fuel[role].name = picked
    config.fuel[role].kind = kindOfName(descriptors, picked)
  end
end

-- Single-button calibration: pressing CAL FUEL takes the current reading as
-- "full" for both pump and tank (empty stays at its existing/default 0).
local function doCalFuel()
  for _, role in ipairs({ "pump", "tank" }) do
    local amount = fuelReaders[role]()
    config.fuel[role].full = amount
    if type(config.fuel[role].empty) ~= "number" then config.fuel[role].empty = 0 end
  end
end

local RELAY_SIDES = { "back", "front", "left", "right", "top", "bottom" }
local function nextSide(cur)
  for i, s in ipairs(RELAY_SIDES) do
    if s == cur then return RELAY_SIDES[(i % #RELAY_SIDES) + 1] end
  end
  return RELAY_SIDES[1]
end

local function applyConfigOp(effect)
  local op = effect.op
  if op == "cycleAssign" then
    config.assign[effect.monitor] = nextAssign(config.assign[effect.monitor])
  elseif op == "stepEngine" then
    local v = (config.engine[effect.field] or 0) + effect.delta
    if v < 0 then v = 0 end
    config.engine[effect.field] = v
    engine:applyConfig(config.engine)
  elseif op == "toggle" then
    config.engine[effect.field] = not config.engine[effect.field]
    engine:applyConfig(config.engine)
  elseif op == "scan" then
    doScan()
  elseif op == "bind" then
    doBind(effect.role)
  elseif op == "calFuel" then
    doCalFuel()
  elseif op == "cycleRelaySide" then
    -- Change the side the engine drives, then re-assert blocked on the new side
    -- (same drain-safety as (re)binding: force a HIGH write so the funnel stays closed).
    config.relay.side = nextSide(config.relay.side)
    rebindRelay()
    engine:blockNow()
  end

  Config.save(CONFIG_PATH, config)
  monitorsResolved = Monitors.resolve(config.assign, monitorNames)
  markDirty()
end

local function applyEffect(effect, now)
  if not effect then return end
  if effect.kind == "command" then
    telLink:send(sender:send(effect.cmd))
  elseif effect.kind == "engine" then
    if effect.op == "on" then engine:setMaster(true, now)
    elseif effect.op == "off" then engine:setMaster(false, now)
    elseif effect.op == "prime" then engine:feedNow(now)
    end
    markDirty()
  elseif effect.kind == "config" then
    applyConfigOp(effect)
  end
end

-- ===== Parallel loops =====

local function netLoop()
  while true do
    local _, _, ch, reply, msg = os.pullEvent("modem_message")
    local f = telLink:onMessage(ch, msg)
    if f then
      rx:accept(f)
    else
      local a = ackLink:onMessage(ch, msg); if a and a.k == "ack" then sender:ack(a.id) end
      local h = hbLink:onMessage(ch, msg);  if h and h.k == "hb" then hbRx:mark(os.epoch("utc") / 1000) end
    end
    markDirty()
  end
end

local function engineTickLoop()
  while true do
    engine:tick(os.epoch("utc"))
    markDirty()
    sleep(0.1)
  end
end

local function fuelPollLoop()
  while true do
    state.pumpFrac = Fuel.read(fuelReaders.pump, config.fuel.pump.kind, config.fuel.pump)
    state.tankFrac = Fuel.read(fuelReaders.tank, config.fuel.tank.kind, config.fuel.tank)
    markDirty()
    sleep(0.5)
  end
end

local function retryLoop()
  while true do
    for _, f in ipairs(sender:tick(0.25)) do telLink:send(f) end
    sleep(0.25)
  end
end

local function touchLoop()
  while true do
    local _, name, x, y = os.pullEvent("monitor_touch")
    local panelId = Monitors.route(config.assign, name)
    if panelId then
      local hits = hitCache[name] or {}
      for _, item in ipairs(hits) do
        if toolkit.hit(item.rect, x, y) then
          local now = os.epoch("utc")
          local effect = panels[panelId].action(item.id, ctxFor(panelId, now))
          applyEffect(effect, now)
          break
        end
      end
    end
  end
end

local function termInputLoop()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "mouse_click" then
      local x, y = b, c
      for _, item in ipairs(termHits) do
        if toolkit.hit(item.rect, x, y) then
          local now = os.epoch("utc")
          local effect = ConfigPanel.action(item.id, configCtx())
          applyEffect(effect, now)
          break
        end
      end
      -- "key" events: no keyboard bindings defined for the Config panel yet;
      -- this branch exists so the loop can be extended without restructuring.
    end
  end
end

local function renderLoop()
  while true do
    os.pullEvent("eh2_redraw")
    redrawPending = false
    redrawAll(os.epoch("utc"))
  end
end

redrawAll(os.epoch("utc"))
parallel.waitForAny(netLoop, engineTickLoop, fuelPollLoop, retryLoop, touchLoop, termInputLoop, renderLoop)
