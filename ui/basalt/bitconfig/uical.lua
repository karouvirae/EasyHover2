-- ui/basalt/bitconfig/uical.lua
-- UI CAL sub-menu (BIT/CONFIG hub, screen id "uical"): the UI-PC device configuration menu.
-- Absorbs everything Task 17's Config page deferred here -- engine relay + fuel pump/tank
-- binding, fuel-gauge calibration, relay side, and engine-feed timing -- MINUS monitor
-- assignment (that stays on the terminal Config panel). Writes /eh2_ui_config.tbl, the SAME
-- file ui/main.lua's Config panel writes today (ui/config.lua's M.save via BasaltApp.CONFIG_PATH).
--
-- Ports ui/main.lua's proven handlers (scanDescriptors/kindOfName/doScan/doBind/doCalFuel/
-- nextSide/applyConfigOp -- see that file's header region, lines ~234-364) onto a runtime table
-- (runtime.config/runtime.engine/runtime.fuelReaders/runtime.rebindRelay) instead of ui/main.lua's
-- module-local upvalues, and REUSES ui/panels/config.lua's M.action for the button-id -> effect
-- mapping (minus the assign: ids, which this menu never emits).
--
-- DRAIN-SAFETY (load-bearing): the funnel above the engine passes items only while its relay
-- output is LOW; holding it HIGH blocks it. After ANY relay change (scan proposing/binding a
-- relay, BIND RELAY cycling to a new one, RELAY SIDE cycling which side is driven) this module
-- calls runtime.rebindRelay() then runtime.engine:blockNow() to re-assert the funnel blocked on
-- the (possibly new) relay/side -- exactly mirroring ui/main.lua's doScan/doBind/applyConfigOp.
-- Skipping this after a relay change would leave the funnel's blocked state asserted on a STALE
-- relay/side while the new one defaults open, silently draining the fuel vault.
--
-- Follows the Task 21/22 template (ui/basalt/bitconfig/tuning.lua / mdb.lua) for the overall
-- shape: `M.id`, `M.title`, Basalt-free PURE/testable seams (M.nextSide, M._applyOp, M._onButton),
-- and `M.build(basalt, frame, runtime, nav, deps) -> { id, apply(state), elements }` with an
-- idempotent apply() (this menu shows CONFIG, not live telemetry; it never polls peripherals on
-- its own -- only the injected `deps.scan`, called on a button click, ever touches peripherals).
--
-- NO peripheral/Basalt access at module LOAD -- scan/wrap only happens inside M.build's onClick
-- closures / M._applyOp, via `deps.scan` (defaulted to the real scanDescriptors defined below,
-- itself only ever CALLED from inside M._applyOp, never at require time). So
-- `require("ui.basalt.bitconfig.uical")` loads clean headless.

local Config      = require("ui.config")
local Detect       = require("ui.detect")
local Fuel         = require("ui.fuel")
local ConfigPanel  = require("ui.panels.config")
local Picker       = require("ui.basalt.picker")
-- NOTE: ui.basalt.app is required LAZILY inside M._applyOp below, NOT at module top -- see
-- ui/basalt/pages/config.lua's header note for the full rationale (ui/basalt/app.lua's page
-- registry requires this module at ITS module top; a top-level require back would loop mid-load).

local M = {}
M.id = "uical"
M.title = "UI CAL"

-- ===== M.nextSide: pure, mirrors ui/main.lua's nextSide over RELAY_SIDES =====

local RELAY_SIDES = { "back", "front", "left", "right", "top", "bottom" }
M.RELAY_SIDES = RELAY_SIDES

-- Picker options for the RELAY SIDE dropdown. Returns a FRESH table every call -- deliberately NOT
-- a cached/shared table: Basalt's Collection:selectItem(idx) (release/basalt-full.lua's
-- Collection.lua) sets `.selected=true` on the picked item WITHOUT clearing any OTHER item's
-- `.selected` flag first (that clearing only happens on a real mouse_click, not the programmatic
-- selectItem path Picker.setOptions uses). A single table reused across multiple setOptions calls
-- (e.g. every refresh(), or two different Picker instances) would accumulate stale `.selected=true`
-- flags on earlier-picked entries, and DropDown:getSelectedItem() returns the FIRST such flagged
-- item in list order -- silently freezing the shown selection at whichever side was selected
-- first, ever. A fresh table per call has no stale flags, so this can't happen (mirrors why
-- M._toOptions/M._fuelCandidates/M._relayCandidates are likewise built fresh on every use).
function M._sideOptions()
  local opts = {}
  for _, s in ipairs(RELAY_SIDES) do
    opts[#opts + 1] = { text = s, value = s }
  end
  return opts
end

function M.nextSide(cur)
  for i, s in ipairs(RELAY_SIDES) do
    if s == cur then return RELAY_SIDES[(i % #RELAY_SIDES) + 1] end
  end
  return RELAY_SIDES[1]
end

-- ===== real scanDescriptors: the default deps.scan. NEVER called at module load. =====
-- Ported verbatim from ui/main.lua's scanDescriptors (peripheral scan -> {name,type,methods}).

local function realScanDescriptors()
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
M._realScanDescriptors = realScanDescriptors

-- Classify a bound name from scanned descriptors via the injected Fuel module (ported from
-- ui/main.lua's kindOfName). Unknown/not-found falls back to "inventory" (matches ui/main.lua).
local function kindOfName(descriptors, name, FuelMod)
  for _, d in ipairs(descriptors) do
    if d.name == name then return FuelMod.kindOf(d.methods) end
  end
  return "inventory"
end

-- ===== M._fuelCandidates / M._relayCandidates: PURE dropdown-population filters, mirroring the =====
-- ===== exact classify math doBind already uses (Fuel.kindOf ~= "unknown" for pump/tank, =====
-- ===== d.type == "redstone_relay" for relay) -- so a picker's option list can never drift from =====
-- ===== what doBind itself would have cycled through. =====

function M._fuelCandidates(descriptors)
  local out = {}
  for _, d in ipairs(descriptors or {}) do
    if Fuel.kindOf(d.methods) ~= "unknown" then out[#out + 1] = d.name end
  end
  return out
end

function M._relayCandidates(descriptors)
  local out = {}
  for _, d in ipairs(descriptors or {}) do
    if d.type == "redstone_relay" then out[#out + 1] = d.name end
  end
  return out
end

-- ===== M._toOptions: candidates -> Picker options, leading with a "(none)"/false unbind entry. =====
-- ===== Shared by uical's own build() and ui/basalt/regions/emc.lua's config screen so both bind =====
-- ===== dropdowns present the identical (none)+candidates shape (mirrors mdb.lua's M.pickerOptions). =====
function M._toOptions(candidates)
  local opts = { { text = "(none)", value = false } }
  for _, name in ipairs(candidates or {}) do
    opts[#opts + 1] = { text = name, value = name }
  end
  return opts
end

-- ===== op handlers: operate on runtime.config/runtime.engine/runtime.fuelReaders/ =====
-- ===== runtime.rebindRelay -- ported from ui/main.lua's doScan/doBind/doCalFuel exactly. =====

local function doScan(runtime, deps)
  local descriptors = deps.scan()
  local proposal = deps.Detect.propose(descriptors)

  if proposal.relay then
    runtime.config.relay.name = proposal.relay
    if not runtime.config.relay.side then runtime.config.relay.side = "back" end
    runtime.rebindRelay()
    runtime.engine:blockNow()
  end
  if proposal.fuel.pump then
    runtime.config.fuel.pump.name = proposal.fuel.pump
    runtime.config.fuel.pump.kind = kindOfName(descriptors, proposal.fuel.pump, deps.Fuel)
  end
  if proposal.fuel.tank then
    runtime.config.fuel.tank.name = proposal.fuel.tank
    runtime.config.fuel.tank.kind = kindOfName(descriptors, proposal.fuel.tank, deps.Fuel)
  end
end

-- role: "relay" | "pump" | "tank". Rescans + cycles to the next matching-type candidate past
-- whatever is currently bound (no persistent candidate list -- same simple approach as
-- ui/main.lua's doBind).
local function doBind(runtime, role, deps)
  local descriptors = deps.scan()
  local candidates = {}
  if role == "relay" then
    for _, d in ipairs(descriptors) do
      if d.type == "redstone_relay" then candidates[#candidates + 1] = d.name end
    end
  else
    for _, d in ipairs(descriptors) do
      if deps.Fuel.kindOf(d.methods) ~= "unknown" then candidates[#candidates + 1] = d.name end
    end
  end
  if #candidates == 0 then return end

  local current
  if role == "relay" then current = runtime.config.relay.name else current = runtime.config.fuel[role].name end
  local idx = 0
  for i, n in ipairs(candidates) do
    if n == current then idx = i break end
  end
  local picked = candidates[(idx % #candidates) + 1]

  if role == "relay" then
    runtime.config.relay.name = picked
    if not runtime.config.relay.side then runtime.config.relay.side = "back" end
    runtime.rebindRelay()
    runtime.engine:blockNow()
  else
    runtime.config.fuel[role].name = picked
    runtime.config.fuel[role].kind = kindOfName(descriptors, picked, deps.Fuel)
  end
end

-- Single-button calibration: the current reading becomes "full" for both pump and tank (empty
-- stays at its existing/default 0). No relay involvement -- no re-block needed here.
local function doCalFuel(runtime)
  for _, role in ipairs({ "pump", "tank" }) do
    local amount = runtime.fuelReaders[role]()
    runtime.config.fuel[role].full = amount
    if type(runtime.config.fuel[role].empty) ~= "number" then runtime.config.fuel[role].empty = 0 end
  end
end

-- ===== M._applyOp: the TESTABLE effectful seam. Ported from ui/main.lua's applyConfigOp, minus =====
-- ===== the cycleAssign branch (monitor assignment is out of scope for this menu). =====
--
-- deps.scan  -- descriptor scanner, () -> {{name=,type=,methods=},...}. Default: realScanDescriptors.
-- deps.Detect / deps.Fuel -- default the real ui.detect / ui.fuel modules.
-- deps.save  -- (path, cfg) -> ok,err. Default: ui.config's M.save.
--
-- ALWAYS persists via save(BasaltApp.CONFIG_PATH, runtime.config) after applying, matching
-- ui/main.lua's applyConfigOp (which calls Config.save unconditionally at the end).
function M._applyOp(runtime, effect, deps)
  local BasaltApp = require("ui.basalt.app")
  deps = deps or {}
  local d = {
    scan = deps.scan or realScanDescriptors,
    Detect = deps.Detect or Detect,
    Fuel = deps.Fuel or Fuel,
  }
  local save = deps.save or Config.save

  local op = effect.op
  if op == "scan" then
    doScan(runtime, d)
  elseif op == "bind" then
    doBind(runtime, effect.role, d)
  elseif op == "calFuel" then
    doCalFuel(runtime)
  elseif op == "cycleRelaySide" then
    -- Change the side the engine drives, then re-assert blocked on the NEW side -- same
    -- drain-safety as (re)binding: force a HIGH write so the funnel stays closed.
    runtime.config.relay.side = M.nextSide(runtime.config.relay.side)
    runtime.rebindRelay()
    runtime.engine:blockNow()
  elseif op == "stepEngine" then
    local v = (runtime.config.engine[effect.field] or 0) + effect.delta
    -- Never let the feed interval reach 0 (that would hold the funnel open = continuous drain);
    -- floor it at one 15s step. pulseMs just stays non-negative.
    local floor = (effect.field == "intervalMs") and 15000 or 0
    if v < floor then v = floor end
    runtime.config.engine[effect.field] = v
    runtime.engine:applyConfig(runtime.config.engine)
  elseif op == "toggle" then
    runtime.config.engine[effect.field] = not runtime.config.engine[effect.field]
    runtime.engine:applyConfig(runtime.config.engine)
  end

  save(BasaltApp.CONFIG_PATH, runtime.config)
end

-- ===== M._pickBind / M._pickSide: the DROPDOWN-pick effectful seams -- SET the chosen value =====
-- ===== directly (no cycling), mirroring doBind/cycleRelaySide's DRAIN-SAFETY discipline exactly. =====
--
-- role: "pump" | "tank" | "relay". `name` is the value a Picker's onPick handed back -- a
-- peripheral name, or `false` for the "(none)" unbind entry. `descriptors` is whatever the caller
-- last scanned (used only to classify a pump/tank pick's kind via kindOfName). deps = { save= }.
--
-- DRAIN SAFETY: every relay pick (bind a new relay OR unbind to false) re-asserts the funnel
-- blocked on the (possibly new/possibly now-absent) relay -- rebindRelay() must re-wrap whatever
-- runtime.config.relay.name now is (nil included) BEFORE blockNow() re-writes it HIGH, exactly
-- like doBind's relay branch. Pump/tank picks never touch the relay, so no re-block there.
function M._pickBind(runtime, role, name, descriptors, deps)
  local BasaltApp = require("ui.basalt.app")
  deps = deps or {}
  local save = deps.save or Config.save

  if role == "relay" then
    runtime.config.relay.name = name
    if not runtime.config.relay.side then runtime.config.relay.side = "back" end
    runtime.rebindRelay()
    runtime.engine:blockNow()
  else
    runtime.config.fuel[role].name = name
    if name then
      -- name == false (the "(none)" unbind pick) leaves .kind alone/default, matching doBind's
      -- own behaviour of only ever classifying an actually-bound name.
      runtime.config.fuel[role].kind = kindOfName(descriptors or {}, name, Fuel)
    end
  end

  save(BasaltApp.CONFIG_PATH, runtime.config)
  return name
end

function M._pickSide(runtime, side, deps)
  local BasaltApp = require("ui.basalt.app")
  deps = deps or {}
  local save = deps.save or Config.save

  runtime.config.relay.side = side
  runtime.rebindRelay()
  runtime.engine:blockNow()

  save(BasaltApp.CONFIG_PATH, runtime.config)
  return side
end

-- ===== M._onButton: the TESTABLE intent seam. Reuses ui/panels/config.lua's M.action for the =====
-- ===== id -> effect mapping (scan/bind*/calFuel/relaySide/pulse*/interval*/toggle* ids only -- =====
-- ===== this menu never emits an "assign:" id). =====
function M._onButton(runtime, id, now, deps)
  local ctx = { config = runtime.config, monitors = {}, detected = runtime.detected }
  local effect = ConfigPanel.action(id, ctx)
  if effect and effect.kind == "config" then
    M._applyOp(runtime, effect, deps)
  end
  return effect
end

-- ===== M.build: construct the element tree =====
-- deps (optional, 5th arg): { scan=, save=, Detect=, Fuel= } -- injectable exactly like
-- tuning.lua's (read,write,delete) / mdb.lua's (read,write,scan) trailing params.

local function fmtInterval(ms)
  if type(ms) ~= "number" then return "?" end
  local totalSec = math.floor(ms / 1000 + 0.5)
  local m = math.floor(totalSec / 60)
  local s = totalSec % 60
  return string.format("%dm%02ds", m, s)
end

function M.build(basalt, frame, runtime, nav, deps)
  deps = deps or {}
  local scanFn = deps.scan or realScanDescriptors

  -- Scanned once at build time (and again on SCAN) to populate the bind/relay pickers' candidate
  -- lists -- see the header note on why this menu never touches peripherals outside a button click.
  local descriptors = scanFn()

  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local headerLabel = frame:addLabel({ x = x, y = 2, width = iw, height = 1, autoSize = false, text = M.title })

  local y = 3
  local function fullBtn(text)
    local b = frame:addButton({ x = x, y = y, width = iw, height = 1, text = text })
    y = y + 1
    return b
  end
  local function pairBtns(leftText, rightText)
    local halfW = math.max(1, math.floor(iw / 2))
    local left  = frame:addButton({ x = x,          y = y, width = halfW, height = 1, text = leftText })
    local right = frame:addButton({ x = x + halfW,  y = y, width = math.max(1, iw - halfW), height = 1, text = rightText })
    y = y + 1
    return left, right
  end

  -- Dropdown pickers replace the old click-to-cycle bind/relay-side buttons -- cycling through
  -- abbreviated peripheral names to find the right one proved unusable in-game (see picker.lua's
  -- header note). Label + dropdown share one row each, same vertical footprint as the old buttons.
  local dropW = math.max(6, math.min(14, math.floor(iw * 0.5)))
  local labelW = math.max(1, iw - dropW - 1)
  local dropX = x + labelW + 1

  local refresh -- forward-declared: picker onPick closures call this; assigned its body below.

  local function pickerRow(labelText, options, current, placeholder, dropdownHeight, onPick)
    local lbl = frame:addLabel({ x = x, y = y, width = labelW, height = 1, autoSize = false, text = labelText })
    local picker = Picker.make(frame, {
      x = dropX, y = y, width = dropW, dropdownHeight = dropdownHeight or 5,
      options = options, current = current, placeholder = placeholder,
      onPick = onPick,
    })
    y = y + 1
    return lbl, picker
  end

  local scanBtn, calFuelBtn = pairBtns("SCAN", "CAL FUEL")

  local cfg0 = runtime.config or {}
  local relayLabel, relayPicker = pickerRow("RELAY",
    M._toOptions(M._relayCandidates(descriptors)), cfg0.relay and cfg0.relay.name, "(none)", 5,
    function(value)
      M._pickBind(runtime, "relay", value, descriptors, deps)
      refresh()
    end)
  local pumpLabel, pumpPicker = pickerRow("PUMP",
    M._toOptions(M._fuelCandidates(descriptors)), cfg0.fuel and cfg0.fuel.pump and cfg0.fuel.pump.name, "(none)", 5,
    function(value)
      M._pickBind(runtime, "pump", value, descriptors, deps)
      refresh()
    end)
  local tankLabel, tankPicker = pickerRow("TANK",
    M._toOptions(M._fuelCandidates(descriptors)), cfg0.fuel and cfg0.fuel.tank and cfg0.fuel.tank.name, "(none)", 5,
    function(value)
      M._pickBind(runtime, "tank", value, descriptors, deps)
      refresh()
    end)
  local sideLabel, sidePicker = pickerRow("SIDE",
    M._sideOptions(), (cfg0.relay and cfg0.relay.side) or "back", "back", 6,
    function(value)
      M._pickSide(runtime, value, deps)
      refresh()
    end)

  local timingLabel = frame:addLabel({ x = x, y = y, width = iw, height = 1, autoSize = false, text = "" })
  y = y + 1

  local pulseDnBtn, pulseUpBtn = pairBtns("PULSE -50", "PULSE +50")
  local intDnBtn, intUpBtn     = pairBtns("INT -15s", "INT +15s")
  local invertBtn, kickBtn     = pairBtns("INVERT", "KICK")

  local backBtn = fullBtn("< BACK")

  -- apply(state)/refresh: idempotent repaint of the picker selections + timing line from
  -- runtime.config. Never polls peripherals -- config-only, like the terminal Config panel (the
  -- candidate LISTS only change on SCAN; the pickers' CURRENT selection always tracks config here).
  refresh = function()
    local cfg = runtime.config or {}
    relayPicker.setOptions(M._toOptions(M._relayCandidates(descriptors)), cfg.relay and cfg.relay.name)
    pumpPicker.setOptions(M._toOptions(M._fuelCandidates(descriptors)), cfg.fuel and cfg.fuel.pump and cfg.fuel.pump.name)
    tankPicker.setOptions(M._toOptions(M._fuelCandidates(descriptors)), cfg.fuel and cfg.fuel.tank and cfg.fuel.tank.name)
    sidePicker.setOptions(M._sideOptions(), (cfg.relay and cfg.relay.side) or "back")
    local e = cfg.engine or {}
    timingLabel:setText(string.format("P %sms  I %s  inv %s  kick %s",
      tostring(e.pulseMs or "?"), fmtInterval(e.intervalMs),
      (e.invert and "on" or "off"), (e.kickstart and "on" or "off")))
  end

  local function onId(id)
    return function()
      M._onButton(runtime, id, os.epoch("utc"), deps)
      refresh()
    end
  end

  -- SCAN both auto-detect-proposes bindings (via M._onButton -> doScan, unchanged) AND re-scans
  -- descriptors so the pickers' candidate lists pick up any newly-connected peripherals.
  scanBtn:onClick(function()
    M._onButton(runtime, "scan", os.epoch("utc"), deps)
    descriptors = scanFn()
    refresh()
  end)
  calFuelBtn:onClick(onId("calFuel"))
  pulseDnBtn:onClick(onId("pulseDn"))
  pulseUpBtn:onClick(onId("pulseUp"))
  intDnBtn:onClick(onId("intervalDn"))
  intUpBtn:onClick(onId("intervalUp"))
  invertBtn:onClick(onId("toggleInvert"))
  kickBtn:onClick(onId("toggleKick"))
  backBtn:onClick(function()
    if nav then nav:pop() end
  end)

  refresh()

  local function apply(_state)
    refresh()
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      headerLabel = headerLabel,
      scanBtn = scanBtn, calFuelBtn = calFuelBtn,
      relayLabel = relayLabel, relayPicker = relayPicker,
      pumpLabel = pumpLabel, pumpPicker = pumpPicker,
      tankLabel = tankLabel, tankPicker = tankPicker,
      sideLabel = sideLabel, sidePicker = sidePicker,
      timingLabel = timingLabel,
      pulseDnBtn = pulseDnBtn, pulseUpBtn = pulseUpBtn,
      intDnBtn = intDnBtn, intUpBtn = intUpBtn,
      invertBtn = invertBtn, kickBtn = kickBtn,
      backBtn = backBtn,
    },
  }
end

return M
