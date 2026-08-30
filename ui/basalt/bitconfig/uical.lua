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
local Theme        = require("ui.theme")
local Detect       = require("ui.detect")
local Fuel         = require("ui.fuel")
local ConfigPanel  = require("ui.panels.config")
local Picker       = require("ui.basalt.picker")
local Region       = require("ui.basalt.region")
local configkit    = require("ui.basalt.configkit")
local switchbtn    = require("ui.basalt.switchbtn")
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
  elseif op == "cycleMode" then
    -- Flip basic<->latch, re-apply the engine config under the new mode, then re-assert blocked
    -- (a mode flip changes how blockNow/feed writes the relay -- see engine.lua's basic vs latch
    -- write paths -- so it needs the SAME re-block discipline as a relay/side change).
    local leavingLatch = (runtime.config.engine.mode == "latch")
    if leavingLatch then
      runtime.config.engine.mode = "basic"
    else
      runtime.config.engine.mode = "latch"
      -- Entering latch: a pulse shorter than LATCH_LINE_MS (150ms, see engine.lua) can't
      -- reliably clear the FEED trigger line before the BLOCK pulse would rise -- same floor
      -- stepEngine enforces going forward. Correct it here too so a value that got below 200
      -- some other way (e.g. floored at 0 in basic mode, then flipped) is saved valid on the
      -- very transition that makes it dangerous. Leaving latch never raises pulseMs.
      if runtime.config.engine.pulseMs < 200 then runtime.config.engine.pulseMs = 200 end
    end
    -- Leave-latch: RESET the Powered Latch via the OLD latch writer/mode FIRST. Engine.mode and
    -- engine.writer are still latch until applyConfig/rebuild; if we rebuild to the basic
    -- 1-arg writer first, blockNow cannot pulse the BLOCK trigger and a mid-feed latch stays SET.
    if leavingLatch then runtime.engine:blockNow() end
    runtime.engine:applyConfig(runtime.config.engine)
    if runtime.rebuildEngineWriter then runtime.rebuildEngineWriter() end
    runtime.rebindRelay()
    runtime.engine:blockNow()
  elseif op == "cycleRelaySide" then
    -- Change the side the engine drives, then re-assert blocked on the NEW side -- same
    -- drain-safety as (re)binding: force a HIGH write so the funnel stays closed.
    -- effect.which selects WHICH side field cycles: nil/"side" = the basic single-side field
    -- (today's behaviour, unchanged); "block"/"feed" = the latch-mode block/feed side fields.
    local which = effect.which
    if which == "block" then
      runtime.config.relay.blockSide = M.nextSide(runtime.config.relay.blockSide)
    elseif which == "feed" then
      runtime.config.relay.feedSide = M.nextSide(runtime.config.relay.feedSide)
    else
      runtime.config.relay.side = M.nextSide(runtime.config.relay.side)
    end
    runtime.rebindRelay()
    runtime.engine:blockNow()
  elseif op == "stepEngine" then
    local v = (runtime.config.engine[effect.field] or 0) + effect.delta
    -- Never let the feed interval reach 0 (that would hold the funnel open = continuous drain);
    -- floor it at one 15s step. pulseMs just stays non-negative, EXCEPT in latch mode: a pulse
    -- shorter than LATCH_LINE_MS (150ms, see engine.lua) can't reliably clear the trigger line,
    -- so floor pulseMs at 200ms there.
    local floor = (effect.field == "intervalMs") and 15000 or 0
    if effect.field == "pulseMs" and runtime.config.engine.mode == "latch" then floor = 200 end
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

function M._pickSide(runtime, side, deps, which)
  local BasaltApp = require("ui.basalt.app")
  deps = deps or {}
  local save = deps.save or Config.save

  if which == "block" then
    runtime.config.relay.blockSide = side
  elseif which == "feed" then
    runtime.config.relay.feedSide = side
  else
    runtime.config.relay.side = side
  end
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

-- ===== M._modeIntent / M._sideIntent: PURE button->intent seams (Task 6) -- uical builds most of=====
-- ===== its intents inline in M.build's onClick closures, but ENG MODE / BLOCK SIDE / FEED SIDE =====
-- ===== extract theirs so the shape is testable headless (no Basalt needed). Both are op-shaped =====
-- ===== effects M._applyOp already handles (cycleMode / cycleRelaySide{which=}) -- these two =====
-- ===== functions ONLY build the effect table; M.build's onClick calls M._applyOp with it. =====
function M._modeIntent()
  return { kind = "config", op = "cycleMode" }
end

function M._sideIntent(which)
  return { kind = "config", op = "cycleRelaySide", which = which }
end

-- ===== M.CATEGORIES / M.CONTROLS_BY_CATEGORY: pure overview->category drilldown mapping =====
-- ===== (Task 5). The old flat ~11-row build() overflowed the ~12-row monitor -- its BACK button =====
-- ===== rendered off-screen. M.build now hosts a region.lua drilldown (root "overview") with one =====
-- ===== screen per category below, each compact enough that its own "<" back always fits. This =====
-- ===== table is the single source of truth for which control lives on which category screen -- =====
-- ===== M.build's devices/fuel/timing screens are built from it, and a coverage test asserts every =====
-- ===== control lands in exactly one category (mirrors mdb.lua's M.GROUPS/M.slotsForGroup pattern). =====
--
-- Control ids here are NOT all ConfigPanel action ids: "relay"/"pump"/"tank"/"side" name the four
-- DEVICES pickers (driven by M._pickBind/M._pickSide directly, never through ConfigPanel.action --
-- see those functions' header notes), while "scan"/"calFuel"/"pulseDn"/"pulseUp"/"intervalDn"/
-- "intervalUp"/"toggleInvert"/"toggleKick" ARE the exact ids M._onButton/ConfigPanel.action expect.
M.CATEGORIES = { "devices", "fuel", "timing", "settings" }

M.CONTROLS_BY_CATEGORY = {
  devices  = { "scan", "relay", "pump", "tank", "side" },
  fuel     = { "calFuel" },
  timing   = { "pulseDn", "pulseUp", "intervalDn", "intervalUp", "toggleInvert", "toggleKick" },
  settings = { "font", "button", "wpt", "rt", "colorblind" },
}

-- M.categoryOf(control) -> the category id owning `control`, or nil if it belongs to none. PURE.
function M.categoryOf(control)
  for _, cat in ipairs(M.CATEGORIES) do
    for _, c in ipairs(M.CONTROLS_BY_CATEGORY[cat] or {}) do
      if c == control then return cat end
    end
  end
  return nil
end

-- ===== M.build: construct the element tree =====
-- deps (optional, 5th arg): { scan=, save=, Detect=, Fuel= } -- injectable exactly like
-- tuning.lua's (read,write,delete) / mdb.lua's (read,write,scan) trailing params.
--
-- Hosts a ui/basalt/region.lua drilldown (root "overview") inside this page's own frame, below a
-- static "UI CAL" headerLabel -- mirrors mdb.lua's overview->group construction EXACTLY (see that
-- module's M.build header note): the overview screen shows the 3 category buttons (M.CATEGORIES)
-- + a "<" that pops the FRAME-level nav, and each category screen shows only that category's
-- controls (M.CONTROLS_BY_CATEGORY) + a "<" that pops the REGION's own nav back to the overview.
-- Every category screen is a handful of rows -- well inside the ~12-row monitor -- so its "<" is
-- always on screen, fixing the old flat build's off-screen BACK.

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

  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local headerLabel = configkit.titleRow(frame, ({ frame:getSize() })[1], M.title)   -- persists on every screen

  -- A region-internal nav push/pop (drilling a category, or backing out of one) isn't a
  -- FRAME-level nav change, so it wouldn't otherwise wake the dirty-gated render loop -- bump
  -- runtime.uiRev, exactly like ui/basalt/bitconfig/mdb.lua's / ui/basalt/pages/flight.lua's
  -- regions do.
  local function bump()
    if runtime then runtime.uiRev = (runtime.uiRev or 0) + 1 end
  end

  -- Scanned once at build time (and again on SCAN, inside the devices screen) to populate the
  -- bind/relay pickers' candidate lists -- see the header note on why this menu never touches
  -- peripherals outside a button click. Shared upvalue: the devices screen's own refresh() always
  -- reads this live, so a SCAN's new descriptors reach it even though Region:showTop() never
  -- rebuilds an already-built screen (only toggles visibility) -- mirrors mdb.lua's RESCAN
  -- convergence note.
  local descriptors = scanFn()

  -- ===== overview screen: DEVICES / FUEL / TIMING + "<" (pops the FRAME-level nav) =====
  local function buildOverview(b, f, region)
    local LABELS = { devices = "DEVICES", fuel = "FUEL", timing = "TIMING", settings = "UI SETTINGS" }
    -- Centred menu column, all buttons sized to the widest label ("UI SETTINGS") -- compact + uniform.
    local items = {}
    for _, cat in ipairs(M.CATEGORIES) do
      items[#items + 1] = { id = cat, label = LABELS[cat] or cat, onClick = function() region:push(cat) end }
    end
    items[#items + 1] = { id = "back", label = "< BACK", onClick = function() if nav then nav:pop() end end }

    local menu = configkit.menuColumn(f, { y = 2, items = items })   -- gap at row 1 (detach from title)
    local catBtns = {}
    for _, cat in ipairs(M.CATEGORIES) do catBtns[cat] = menu.buttons[cat] end

    -- apply(state): overview is static category labels + the back row -- a no-op repaint suffices.
    local function apply(_state) end

    return { apply = apply, elements = { catBtns = catBtns, backRow = { buttons = { menu.buttons.back } } } }
  end

  -- ===== devices screen: SCAN + RELAY/PUMP/TANK/SIDE pickers + "<" (pops the region's own nav) =====
  -- Wires the SAME M._onButton("scan")/M._pickBind/M._pickSide seams the old flat build used --
  -- byte-identical effect, including the relay drain-safety re-block (rebindRelay + blockNow)
  -- those functions perform internally; only WHERE the controls live on screen changed.
  local function buildDevices(b, f, region)
    local fw, fh = f:getSize()
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 1

    -- Compact: short label + a capped-width dropdown, centred as a block (not spanning the row).
    local dropW = math.max(6, math.min(14, math.floor(fiw * 0.5)))
    local labelW = 6
    local blockX = fx + math.max(0, math.floor((fiw - (labelW + 1 + dropW + 2)) / 2))   -- +2 = picker brackets
    local dropX = blockX + labelW + 1

    local refresh -- forward-declared: SCAN + every picker's onPick call this; assigned below.

    local function pickerRow(labelText, options, current, placeholder, dropdownHeight, onPick)
      local lbl = f:addLabel({ x = blockX, y = y, width = labelW, height = 1, autoSize = false, text = labelText })
      local picker = Picker.make(f, {
        x = dropX, y = y, width = dropW, dropdownHeight = dropdownHeight or 5,
        options = options, current = current, placeholder = placeholder,
        onPick = onPick,
      })
      y = y + 1
      return lbl, picker
    end

    local function setRowY(label, widget, row)
      if label and label.setY then label:setY(row) end
      if widget.trigger and widget.trigger.setY then widget.trigger:setY(row)
      elseif widget.button and widget.button.setY then widget.button:setY(row) end
    end

    local function setRowVisible(label, widget, vis)
      if label and label.setVisible then label:setVisible(vis) end
      if widget.trigger and widget.trigger.setVisible then widget.trigger:setVisible(vis)
      elseif widget.button and widget.button.setVisible then widget.button:setVisible(vis) end
    end

    -- SCAN both auto-detect-proposes bindings (via M._onButton -> doScan, unchanged) AND re-scans
    -- descriptors so the pickers' candidate lists pick up any newly-connected peripherals.
    local scanRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "SCAN", onClick = function()
          M._onButton(runtime, "scan", os.epoch("utc"), deps)
          descriptors = scanFn()
          refresh()
        end },
    })
    y = y + 1

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

    -- MODE + SIDE/BLOCK/FEED: left labels (never fitLabel'd with a colon -- fitLabel strips at
    -- ":") and picker-row layout matching RELAY/PUMP/TANK. SIDE is basic-only; BLOCK/FEED are
    -- latch-only. refresh() relayouts + toggles visibility so BACK (pinned to fh) stays on screen.
    local modeLabel = f:addLabel({ x = blockX, y = y, width = labelW, height = 1, autoSize = false, text = "MODE" })
    local modeSw = switchbtn.make(f, { x = dropX, y = y, width = dropW, height = 1, text = "basic" })
    modeSw.button:onClick(function()
      M._applyOp(runtime, M._modeIntent(), deps)
      refresh()
    end)
    y = y + 1

    local sideLabel, sidePicker = pickerRow("SIDE",
      M._sideOptions(), (cfg0.relay and cfg0.relay.side) or "back", "back", 6,
      function(value)
        M._pickSide(runtime, value, deps)
        refresh()
      end)
    local blockLabel, blockPicker = pickerRow("BLOCK",
      M._sideOptions(), (cfg0.relay and cfg0.relay.blockSide) or "back", "back", 6,
      function(value)
        M._pickSide(runtime, value, deps, "block")
        refresh()
      end)
    local feedLabel, feedPicker = pickerRow("FEED",
      M._sideOptions(), (cfg0.relay and cfg0.relay.feedSide) or "back", "back", 6,
      function(value)
        M._pickSide(runtime, value, deps, "feed")
        refresh()
      end)

    local backRow = configkit.actionRow(f, { x = fx, y = fh, w = fiw }, {
      { id = "back", label = "<", onClick = function() region:pop() end },
    })

    refresh = function()
      local cfg = runtime.config or {}
      relayPicker.setOptions(M._toOptions(M._relayCandidates(descriptors)), cfg.relay and cfg.relay.name)
      pumpPicker.setOptions(M._toOptions(M._fuelCandidates(descriptors)), cfg.fuel and cfg.fuel.pump and cfg.fuel.pump.name)
      tankPicker.setOptions(M._toOptions(M._fuelCandidates(descriptors)), cfg.fuel and cfg.fuel.tank and cfg.fuel.tank.name)
      sidePicker.setOptions(M._sideOptions(), (cfg.relay and cfg.relay.side) or "back")
      blockPicker.setOptions(M._sideOptions(), (cfg.relay and cfg.relay.blockSide) or "back")
      feedPicker.setOptions(M._sideOptions(), (cfg.relay and cfg.relay.feedSide) or "back")

      local mode = (cfg.engine and cfg.engine.mode) or "basic"
      local latch = mode == "latch"
      modeSw.button:setText(mode)
      modeSw.set(latch and "on" or "off")

      local row = 5
      setRowY(modeLabel, modeSw, row)
      row = row + 1
      setRowVisible(sideLabel, sidePicker, not latch)
      setRowVisible(blockLabel, blockPicker, latch)
      setRowVisible(feedLabel, feedPicker, latch)
      if latch then
        setRowY(blockLabel, blockPicker, row)
        row = row + 1
        setRowY(feedLabel, feedPicker, row)
      else
        setRowY(sideLabel, sidePicker, row)
      end
    end
    refresh()

    return {
      apply = function(_state) refresh() end,
      elements = {
        scanRow = scanRow,
        relayLabel = relayLabel, relayPicker = relayPicker,
        pumpLabel = pumpLabel, pumpPicker = pumpPicker,
        tankLabel = tankLabel, tankPicker = tankPicker,
        sideLabel = sideLabel, sidePicker = sidePicker,
        modeLabel = modeLabel, modeSw = modeSw,
        blockLabel = blockLabel, blockPicker = blockPicker,
        feedLabel = feedLabel, feedPicker = feedPicker,
        backRow = backRow,
      },
    }
  end

  -- ===== fuel screen: CAL FUEL + the calibrated reading + "<" (pops the region's own nav) =====
  -- "the reading" is the config-held calibrated full amount for pump/tank (what CAL FUEL just
  -- captured via runtime.fuelReaders) -- read-only from runtime.config, so refresh() stays a pure
  -- config readout and never itself polls a fuel reader (matches this menu's "never polls
  -- peripherals on its own, only on a button click" discipline).
  local function buildFuel(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 1

    local refresh -- forward-declared: CAL FUEL's onClick calls this; assigned below.

    local calFuelRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "CAL FUEL", onClick = function()
          M._onButton(runtime, "calFuel", os.epoch("utc"), deps)
          refresh()
        end },
    })
    y = y + 1

    local readingLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1

    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { id = "back", label = "<", onClick = function() region:pop() end },
    })

    refresh = function()
      local cfg = runtime.config or {}
      local pump = (cfg.fuel and cfg.fuel.pump) or {}
      local tank = (cfg.fuel and cfg.fuel.tank) or {}
      readingLabel:setText(configkit.fitLabel(
        string.format("PMP %s  TANK %s", tostring(pump.full or 0), tostring(tank.full or 0)), fiw))
    end
    refresh()

    return {
      apply = function(_state) refresh() end,
      elements = { calFuelRow = calFuelRow, readingLabel = readingLabel, backRow = backRow },
    }
  end

  -- ===== timing screen: PULSE +/-, INTERVAL +/-, INVERT/KICK + the timing summary + "<" =====
  local function buildTiming(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 1

    local refresh -- forward-declared: every row's onClick calls this; assigned below.

    local function onId(id)
      return function()
        M._onButton(runtime, id, os.epoch("utc"), deps)
        refresh()
      end
    end

    local pulseRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "PULSE -50", onClick = onId("pulseDn") },
      { label = "PULSE +50", onClick = onId("pulseUp") },
    })
    y = y + 1

    local intRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "INT -15s", onClick = onId("intervalDn") },
      { label = "INT +15s", onClick = onId("intervalUp") },
    })
    y = y + 1

    local toggleRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "INVERT", onClick = onId("toggleInvert") },
      { label = "KICK",   onClick = onId("toggleKick") },
    })
    y = y + 1

    local timingLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1

    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { id = "back", label = "<", onClick = function() region:pop() end },
    })

    refresh = function()
      local e = (runtime.config and runtime.config.engine) or {}
      timingLabel:setText(configkit.fitLabel(string.format("P %sms  I %s  inv %s  kick %s",
        tostring(e.pulseMs or "?"), fmtInterval(e.intervalMs),
        (e.invert and "on" or "off"), (e.kickstart and "on" or "off")), fiw))
    end
    refresh()

    return {
      apply = function(_state) refresh() end,
      elements = { pulseRow = pulseRow, intRow = intRow, toggleRow = toggleRow, timingLabel = timingLabel, backRow = backRow },
    }
  end

  -- ===== settings screen: UI colour scheme -- FONT/BUTTON/NAV WPT/NAV RT/COLORBLIND pickers + "<" =====
  -- Each picker writes runtime.config.colors.<role>, persists the whole config (same file + save as
  -- every other UI CAL control), and re-applies the live theme+palette via runtime.applyColors (set
  -- by ui/basalt/app.lua's M.run; absent headless, so guarded). Background stays hardcoded black
  -- (ui/theme.lua). State-feedback colours are set on their own elements and are unaffected.
  local function buildSettings(b, f, region)
    local fw, fh = f:getSize()
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 2   -- gap at row 1 (detach from title)
    -- Compact: label + capped dropdown, centred as a block (not spanning the row).
    local dropW = math.max(8, math.min(14, math.floor(fiw * 0.45)))
    local labelW = 10
    local blockX = fx + math.max(0, math.floor((fiw - (labelW + 1 + dropW + 2)) / 2))   -- +2 = picker brackets
    local dropX = blockX + labelW + 1

    local function colorOpts()
      local o = {}
      for _, c in ipairs(Theme.COLOR_CHOICES) do o[#o + 1] = { text = c[2], value = c[1] } end
      return o
    end
    local function cbOpts()
      local o = {}
      for _, c in ipairs(Theme.COLORBLIND_MODES) do o[#o + 1] = { text = c[2], value = c[1] } end
      return o
    end

    local function pick(role, value)
      runtime.config.colors = runtime.config.colors or {}
      runtime.config.colors[role] = value
      local save = deps.save or Config.save
      save(require("ui.basalt.app").CONFIG_PATH, runtime.config)
      if runtime.applyColors then runtime.applyColors() end
    end

    local function row(labelText, options, current, role)
      f:addLabel({ x = blockX, y = y, width = labelW, height = 1, autoSize = false, text = labelText })
      local picker = Picker.make(f, {
        x = dropX, y = y, width = dropW, dropdownHeight = 6,
        options = options, current = current, onPick = function(v) pick(role, v) end,
      })
      y = y + 1
      return picker
    end

    local c = runtime.config.colors or {}
    local d = Theme.DEFAULTS
    local fontPicker   = row("FONT COLOR", colorOpts(), c.font or d.font, "font")
    local buttonPicker = row("BUTTON COL", colorOpts(), c.button or d.button, "button")
    local wptPicker    = row("NAV WPT", colorOpts(), c.wpt or d.wpt, "wpt")
    local rtPicker     = row("NAV RT", colorOpts(), c.rt or d.rt, "rt")
    local cbPicker     = row("COLORBLIND", cbOpts(), c.colorblind or d.colorblind, "colorblind")

    local backRow = configkit.actionRow(f, { x = fx, y = fh, w = fiw }, {
      { id = "back", label = "<", onClick = function() region:pop() end },
    })

    return {
      apply = function(_state) end,
      elements = { fontPicker = fontPicker, buttonPicker = buttonPicker, wptPicker = wptPicker,
                   rtPicker = rtPicker, cbPicker = cbPicker, backRow = backRow },
    }
  end

  local region = Region.new(basalt, frame, {
    x = 1, y = 2, width = w, height = math.max(1, h - 1),
    root = "overview", onNav = bump,
    screens = {
      overview = buildOverview,
      devices  = buildDevices,
      fuel     = buildFuel,
      timing   = buildTiming,
      settings = buildSettings,
    },
  })

  -- Force the overview screen to build now (not on the first scheduled apply()), so its elements
  -- exist as soon as M.build returns -- mirrors mdb.lua's identical eager-build call.
  region:apply(nil)

  -- apply(state): this menu shows CONFIG, not live telemetry -- forwards to the region, which
  -- lazily builds/shows its current nav top and repaints only that screen. Never polls
  -- peripherals on its own; SCAN/CAL FUEL are the only things that touch peripherals, and only on
  -- click.
  local function apply(state)
    region:apply(state)
  end

  return {
    id = M.id,
    apply = apply,
    elements = { headerLabel = headerLabel, region = region },
  }
end

return M
