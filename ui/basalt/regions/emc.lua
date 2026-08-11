-- ui/basalt/regions/emc.lua
-- EMC region screens for the merged "flight" cockpit page (top region over an FCS region --
-- see docs/superpowers/specs/2026-08-10-eh2-merged-flight-page-design.md). Each screen is a
-- BUILDER `function(basalt, subFrame, region, runtime) -> { apply = function(state) end }`
-- matching ui/basalt/region.lua's contract EXACTLY -- `subFrame:getSize()` gives the region's
-- fixed area (width ~= 14 on the target overhead monitor at text scale 0.5); `region:push(id)` /
-- `region:pop()` drive THIS region's own nav stack.
--
-- Three screens, drilling deeper each time:
--   M.main    ("emc_main")    -- flight-glance: gauges + ENG SW/PRIME + MASTER/FEED lights + CONFIG
--   M.config  ("emc_config")  -- relay/pulse/interval/bind controls, reusing UI CAL's tested seams
--   M.calfuel ("emc_calfuel") -- manual max steppers (no auto-cal) that the gauges divide against
--
-- REUSE, not reimplementation:
--   * ui/basalt/switchbtn.lua's Switch.make/set for the ENG SW color-state button.
--   * ui/basalt/bitconfig/uical.lua's M._onButton for the config-drill button ids that stay
--     buttons (pulseUp/Dn, intervalUp/Dn) via M._cfg below -- NOT "calFuel" (the old single-button
--     auto-cal); this module's own M._setMax is the manual replacement.
--   * ui/basalt/picker.lua's Picker.make + uical.lua's _sideOptions/_fuelCandidates/
--     _relayCandidates/_toOptions/_pickBind/_pickSide for RELAY SIDE and BIND PUMP/TANK/RELAY --
--     DROPDOWNS, not click-to-cycle buttons (cycling abbreviated peripheral names to find the
--     right one proved unusable in-game). These bypass M._cfg/_onButton entirely (a Picker's
--     onPick hands back the tapped value directly, so there's nothing to "cycle to next" through
--     ConfigPanel.action) -- each onPick calls uical's _pickBind/_pickSide then bumps
--     runtime.uiRev itself (see M.config's local `bump()`).
--   * ui/fuel.lua's Fuel.manualFrac for both gauges' fill fraction (amount / config-set max).
--
-- RENDER-PATH DISCIPLINE: apply(state) reads ONLY `state` (the polled cadence snapshot -- already
-- carries pumpAmount/tankMb, ui/basalt/app.lua:M.buildState) and `runtime.config` (edits bump
-- runtime.uiRev, which the cadence gate already keys on) -- it NEVER calls a peripheral or a
-- fuelReader directly. Every apply() is idempotent -- safe to call repeatedly.
--
-- ASCII-ONLY (real CC:Tweaked font has no bullet glyph): the MASTER/FEED "lights" are a 1-char
-- Label whose BACKGROUND is set green/red (a colored block), not a unicode dot, plus a short text
-- label beside it -- verified against ui/basalt/switchbtn.lua's own note on the same point.
--
-- Basalt element/method surface verified against release/basalt-full.lua (not from memory):
--   * Button:render() (release/basalt-full.lua:3980-3984) truncates its OWN text to `width` via
--     `da:sub(1,width)` -- so a bind button's text can safely exceed width; it just clips, no wrap.
--   * Label.autoSize=false (release/basalt-full.lua:4822-4825, see ui/basalt/pages/emc.lua's header
--     note) WRAPS text at the label's current width instead of clipping -- every Label text here is
--     pre-truncated with the local `fit()` helper so a long value can never push later rows down.
--   * addProgressBar/addLabel/addButton/getSize/setProgress/setText/setBackground/setForeground/
--     setEnabled/onClick -- all confirmed call sites already exist in ui/basalt/pages/emc.lua and
--     ui/basalt/bitconfig/uical.lua (same auto-generated Container:add<Element> / defineProperty
--     accessor pattern), reused verbatim here.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.main/M.config/M.calfuel/
-- M._onEngine/M._cfg/M._setMax, so `require("ui.basalt.regions.emc")` loads clean headless.
local Switch = require("ui.basalt.switchbtn")
local Fuel   = require("ui.fuel")
local Uical  = require("ui.basalt.bitconfig.uical")
local Config = require("ui.config")
local ConfigPanel = require("ui.panels.config")
local Picker = require("ui.basalt.picker")

local M = {}

-- Manual-max stepper sizes: a stack (64) for the solid pump max, one bucket (1000 mB) for the
-- liquid tank max -- pinned constants so M.calfuel's onClick wiring and tests agree on the exact
-- delta without duplicating the literal.
M.SOLID_STEP  = 64
M.LIQUID_STEP = 1000

-- Truncate (never wrap) a Label's text to its element width -- see the header note on
-- Label.autoSize=false's wrap-at-width behaviour. Buttons don't need this (Button:render() already
-- clips its own text), but every Label built below routes through this first.
local function fit(s, w)
  s = tostring(s)
  if type(w) == "number" and w > 0 and #s > w then
    return s:sub(1, w)
  end
  return s
end

-- relayBound: NOT part of the canonical flat cadence state -- derive it from runtime.config.relay
-- at the point of use, exactly like ui/basalt/pages/emc.lua's own relayBound() does (config edits
-- bump uiRev, which forces a repaint through the cadence gate, so this stays fresh).
local function relayBound(runtime)
  local r = runtime.config.relay
  return r ~= nil and r.name ~= nil
end

-- ===== M._onEngine: the TESTABLE intent seam for emc_main's ENG SW / PRIME controls. No Basalt. =====
--
-- id=="engSw" -> toggles the engine master, but ONLY when a relay is bound (gated inert otherwise,
-- no text about it -- per the design). id=="prime" -> forces one manual feed pulse, but ONLY when a
-- relay is bound AND the master is currently on. Returns the action taken ({op=...}) or nil when
-- gated off / an unrecognised id.
function M._onEngine(runtime, id, now)
  if id == "engSw" then
    if not relayBound(runtime) then return nil end
    runtime.engine:toggleMaster(now)
    return { op = "toggleMaster" }
  elseif id == "prime" then
    if not relayBound(runtime) then return nil end
    local st = runtime.engine:status(now)
    if not st.master then return nil end
    runtime.engine:feedNow(now)
    return { op = "feedNow" }
  end
  return nil
end

-- ===== M._cfg: thin delegate onto UI CAL's already-tested intent seam. No reimplementation. =====
-- Valid ids: relaySide, pulseUp/pulseDn, intervalUp/intervalDn, bindPump/bindTank/bindRelay,
-- toggleInvert/toggleKick. Deliberately never "calFuel" -- M._setMax below is the manual replacement.
--
-- uical._onButton -> _applyOp saves runtime.config to disk but does NOT bump runtime.uiRev, and
-- the cadence signature (ui/basalt/cadence.lua) has no field for relay name/side, pulseMs,
-- intervalMs, or bind names -- so a uiRev bump here is the ONLY thing that forces the merged
-- page's render-gate to repaint emc_config's labels after a bind/relaySide/pulse/interval edit
-- (mirrors ui/basalt/pages/config.lua's M._onButton, which bumps uiRev itself for the identical
-- reason). Bumped unconditionally after delegating, regardless of the effect uical returns.
function M._cfg(runtime, id, deps)
  local effect = Uical._onButton(runtime, id, os.epoch("utc"), deps)
  runtime.uiRev = (runtime.uiRev or 0) + 1
  return effect
end

-- ===== M._setMax: pure-of-Basalt manual-max stepper for emc_calfuel. =====
-- role: "pump" | "tank". Clamps at 0, persists via saveFn (default ui.config's M.save against
-- BasaltApp.CONFIG_PATH -- required LAZILY, mirroring ui/basalt/pages/config.lua's own
-- M._onButton, since ui.basalt.app does not require this module back), and bumps runtime.uiRev so
-- the cadence gate repaints. Returns the new max.
function M._setMax(runtime, role, delta, saveFn)
  local BasaltApp = require("ui.basalt.app")
  local save = saveFn or Config.save
  local fc = runtime.config.fuel[role]
  local newFull = math.max(0, (fc.full or 0) + (delta or 0))
  fc.full = newFull
  save(BasaltApp.CONFIG_PATH, runtime.config)
  runtime.uiRev = (runtime.uiRev or 0) + 1
  return newFull
end

-- ===== M.main ("emc_main"): flight-glance view, ~10 rows =====

function M.main(basalt, frame, region, runtime)
  local w = ({ frame:getSize() })[1]

  -- Row 1: PMP gauge (solid fuel, %). Widths: "PMP" label(3) + bar(rest) + pct label(4, fits "100%").
  local pmpLabelW, pctW = 3, 4
  local pmpBarW = math.max(1, w - pmpLabelW - pctW)
  frame:addLabel({ x = 1, y = 1, width = pmpLabelW, height = 1, autoSize = false, text = "PMP" })
  local pmpBar = frame:addProgressBar({ x = 1 + pmpLabelW, y = 1, width = pmpBarW, height = 1 })
  local pmpPctLabel = frame:addLabel({ x = 1 + pmpLabelW + pmpBarW, y = 1, width = pctW, height = 1, autoSize = false, text = "0%" })

  -- Row 2: MAIN gauge (liquid fuel, raw mB). "MAIN" label(4) + bar(rest) + mB label(5).
  local mainLabelW, mbW = 4, 5
  local mainBarW = math.max(1, w - mainLabelW - mbW)
  frame:addLabel({ x = 1, y = 2, width = mainLabelW, height = 1, autoSize = false, text = "MAIN" })
  local mainBar = frame:addProgressBar({ x = 1 + mainLabelW, y = 2, width = mainBarW, height = 1 })
  local mainMbLabel = frame:addLabel({ x = 1 + mainLabelW + mainBarW, y = 2, width = mbW, height = 1, autoSize = false, text = "0" })

  -- Row 3: spacer.

  -- Rows 4-6: ENG SW / PRIME, side by side, 3 rows tall.
  local ctrlY = 4
  local halfW = math.max(1, math.floor(w / 2))
  local restW = math.max(1, w - halfW)
  local engSw = Switch.make(frame, { x = 1, y = ctrlY, width = halfW, height = 3, text = "ENG SW" })
  local primeBtn = frame:addButton({ x = 1 + halfW, y = ctrlY, width = restW, height = 3, text = "PRIME" })

  -- Row 7: spacer.

  -- Row 8: MASTER light (1-char colored block + short label).
  local lightY = ctrlY + 3 + 1
  local masterBlock = frame:addLabel({ x = 1, y = lightY, width = 1, height = 1, autoSize = false, text = " " })
  local masterText  = frame:addLabel({ x = 2, y = lightY, width = math.max(1, w - 1), height = 1, autoSize = false, text = "ENG OFF" })

  -- Row 9: FEED light.
  local feedY = lightY + 1
  local feedBlock = frame:addLabel({ x = 1, y = feedY, width = 1, height = 1, autoSize = false, text = " " })
  local feedText  = frame:addLabel({ x = 2, y = feedY, width = math.max(1, w - 1), height = 1, autoSize = false, text = "FEED no" })

  -- Row 10: CONFIG drill-in.
  local configY = feedY + 1
  local configBtn = frame:addButton({ x = 1, y = configY, width = w, height = 1, text = "CONFIG" })

  engSw.button:onClick(function()
    M._onEngine(runtime, "engSw", os.epoch("utc"))
  end)
  primeBtn:onClick(function()
    M._onEngine(runtime, "prime", os.epoch("utc"))
  end)
  configBtn:onClick(function()
    region:push("emc_config")
  end)

  -- apply(state): idempotent repaint from `state` + runtime.config ONLY -- no peripheral polling.
  local function apply(state)
    state = state or {}
    local cfg = runtime.config

    local pumpPct = math.floor(Fuel.manualFrac(state.pumpAmount, cfg.fuel.pump.full) * 100 + 0.5)
    pmpBar:setProgress(pumpPct)
    pmpPctLabel:setText(fit(pumpPct .. "%", pctW))

    local mainFrac = Fuel.manualFrac(state.tankMb, cfg.fuel.tank.full)
    mainBar:setProgress(math.floor(mainFrac * 100 + 0.5))
    mainMbLabel:setText(fit(state.tankMb or 0, mbW))

    local bound = relayBound(runtime)
    engSw.set(bound and (state.engineMaster and "on" or "off") or "disabled")

    local primeEnabled = bound and (state.engineMaster and true or false)
    primeBtn:setEnabled(primeEnabled)
    primeBtn:setBackground(primeEnabled and colors.lightBlue or colors.gray)
    primeBtn:setForeground(primeEnabled and colors.black or colors.lightGray)

    masterBlock:setBackground(state.engineMaster and colors.green or colors.red)
    masterText:setText(fit(state.engineMaster and "ENG ON" or "ENG OFF", w - 1))

    feedBlock:setBackground(state.feeding and colors.green or colors.red)
    feedText:setText(fit(state.feeding and "FEED yes" or "FEED no", w - 1))
  end

  apply({})

  return {
    apply = apply,
    elements = {
      pmpBar = pmpBar, pmpPctLabel = pmpPctLabel,
      mainBar = mainBar, mainMbLabel = mainMbLabel,
      engSw = engSw, primeBtn = primeBtn,
      masterBlock = masterBlock, masterText = masterText,
      feedBlock = feedBlock, feedText = feedText,
      configBtn = configBtn,
    },
  }
end

-- ===== M.config ("emc_config"): engine config drill, ~11 rows =====

-- deps (optional, 5th arg): { scan= } -- injectable exactly like uical.build's trailing deps;
-- defaults to Uical._realScanDescriptors (the SAME real scanner uical.lua's own menu uses -- no
-- second implementation). Scanned once at build time to populate the four pickers' candidate
-- lists; this screen has no dedicated RESCAN control (SCAN+auto-detect lives on UI CAL), so the
-- candidate lists are fixed for the screen's lifetime -- only each picker's CURRENT selection is
-- refreshed afterwards, from runtime.config, on every apply().
function M.config(basalt, frame, region, runtime, deps)
  deps = deps or {}
  local scanFn = deps.scan or Uical._realScanDescriptors
  local descriptors = scanFn()

  local w = ({ frame:getSize() })[1]
  local half = math.max(1, math.floor(w / 2))
  local rest = math.max(1, w - half)
  local y = 1

  local backBtn = frame:addButton({ x = 1, y = y, width = w, height = 1, text = "< BACK" })
  y = y + 1

  -- Dropdown pickers replace the old click-to-cycle RELAY SIDE / BIND PUMP/TANK/RELAY buttons --
  -- reuses uical.lua's tested _sideOptions / _fuelCandidates / _relayCandidates / _toOptions
  -- / _pickBind / _pickSide seams verbatim, no reimplementation. Label + dropdown share one row.
  local labelW = math.min(4, math.max(1, w - 3))
  local dropW  = math.max(3, w - labelW)
  local dropX  = 1 + labelW

  local function pickerRow(labelText, options, current, placeholder, dropdownHeight, onPick)
    local lbl = frame:addLabel({ x = 1, y = y, width = labelW, height = 1, autoSize = false, text = labelText })
    local picker = Picker.make(frame, {
      x = dropX, y = y, width = dropW, dropdownHeight = dropdownHeight or 5,
      options = options, current = current, placeholder = placeholder,
      onPick = onPick,
    })
    y = y + 1
    return lbl, picker
  end

  -- Every pick bumps runtime.uiRev itself (bypasses M._cfg, which only wraps ConfigPanel.action
  -- ids) -- see the header note: uical's _pickBind/_pickSide save config but don't touch uiRev,
  -- and the cadence signature has no field for relay/bind names or sides, so this is the ONLY
  -- thing that wakes the dirty-gated render loop to repaint the picker's new selection.
  local function bump() runtime.uiRev = (runtime.uiRev or 0) + 1 end

  local cfg0 = runtime.config
  local sideLabel, sidePicker = pickerRow("SIDE",
    Uical._sideOptions(), (cfg0.relay and cfg0.relay.side) or "back", "back", 6,
    function(value)
      Uical._pickSide(runtime, value, deps)
      bump()
    end)

  local timingLabel = frame:addLabel({ x = 1, y = y, width = w, height = 1, autoSize = false, text = "" })
  y = y + 1

  local pulseDnBtn = frame:addButton({ x = 1, y = y, width = half, height = 1, text = "PULSE-" })
  local pulseUpBtn = frame:addButton({ x = 1 + half, y = y, width = rest, height = 1, text = "PULSE+" })
  y = y + 1

  local intDnBtn = frame:addButton({ x = 1, y = y, width = half, height = 1, text = "INT-" })
  local intUpBtn = frame:addButton({ x = 1 + half, y = y, width = rest, height = 1, text = "INT+" })
  y = y + 1

  y = y + 1 -- spacer

  -- Candidate NAME lists computed ONCE from the build-time scan (no peripheral touch from
  -- apply()) -- but the Picker OPTIONS built from them are NOT cached: Uical._toOptions(...) is
  -- called fresh every time a picker's options are set (here, and again in apply() below). A
  -- cached/shared options TABLE reused across multiple setOptions calls hits the exact same
  -- stale-.selected hazard documented on uical.lua's M._sideOptions -- Basalt's
  -- Collection:selectItem(idx) never clears a previously-selected item's flag, so reusing one
  -- table across calls would eventually freeze the shown selection at whichever candidate was
  -- selected first, ever.
  local pumpCandidates  = Uical._fuelCandidates(descriptors)
  local tankCandidates  = Uical._fuelCandidates(descriptors)
  local relayCandidates = Uical._relayCandidates(descriptors)

  local pumpLabel, pumpPicker = pickerRow("PMP", Uical._toOptions(pumpCandidates), cfg0.fuel.pump.name, "(none)", 5,
    function(value)
      Uical._pickBind(runtime, "pump", value, descriptors, deps)
      bump()
    end)
  local tankLabel, tankPicker = pickerRow("TNK", Uical._toOptions(tankCandidates), cfg0.fuel.tank.name, "(none)", 5,
    function(value)
      Uical._pickBind(runtime, "tank", value, descriptors, deps)
      bump()
    end)
  local relayLabel, relayPicker = pickerRow("RLY", Uical._toOptions(relayCandidates), cfg0.relay and cfg0.relay.name, "(none)", 5,
    function(value)
      Uical._pickBind(runtime, "relay", value, descriptors, deps)
      bump()
    end)

  y = y + 1 -- spacer

  local calFuelBtn = frame:addButton({ x = 1, y = y, width = w, height = 1, text = "CAL FUEL" })
  y = y + 1

  backBtn:onClick(function() region:pop() end)
  pulseDnBtn:onClick(function() M._cfg(runtime, "pulseDn") end)
  pulseUpBtn:onClick(function() M._cfg(runtime, "pulseUp") end)
  intDnBtn:onClick(function() M._cfg(runtime, "intervalDn") end)
  intUpBtn:onClick(function() M._cfg(runtime, "intervalUp") end)
  calFuelBtn:onClick(function() region:push("emc_calfuel") end)

  -- apply(state): reads ONLY state + runtime.config (per the header's RENDER-PATH DISCIPLINE) --
  -- refreshes the timing line and each picker's CURRENT selection; candidate lists stay fixed
  -- (from the build-time scan) since this screen has no rescan control.
  local function apply(state)
    state = state or {}
    local cfg = runtime.config

    timingLabel:setText(ConfigPanel.timingLine(cfg, w))

    sidePicker.setOptions(Uical._sideOptions(), (cfg.relay and cfg.relay.side) or "back")
    pumpPicker.setOptions(Uical._toOptions(pumpCandidates), cfg.fuel.pump.name)
    tankPicker.setOptions(Uical._toOptions(tankCandidates), cfg.fuel.tank.name)
    relayPicker.setOptions(Uical._toOptions(relayCandidates), cfg.relay and cfg.relay.name)
  end

  apply({})

  return {
    apply = apply,
    elements = {
      backBtn = backBtn, sideLabel = sideLabel, sidePicker = sidePicker, timingLabel = timingLabel,
      pulseDnBtn = pulseDnBtn, pulseUpBtn = pulseUpBtn,
      intDnBtn = intDnBtn, intUpBtn = intUpBtn,
      pumpLabel = pumpLabel, pumpPicker = pumpPicker,
      tankLabel = tankLabel, tankPicker = tankPicker,
      relayLabel = relayLabel, relayPicker = relayPicker,
      calFuelBtn = calFuelBtn,
    },
  }
end

-- ===== M.calfuel ("emc_calfuel"): manual max steppers, ~8 rows, room to grow =====

function M.calfuel(basalt, frame, region, runtime)
  local w = ({ frame:getSize() })[1]
  local half = math.max(1, math.floor(w / 2))
  local rest = math.max(1, w - half)
  local y = 1

  local backBtn = frame:addButton({ x = 1, y = y, width = w, height = 1, text = "< BACK" })
  y = y + 1
  y = y + 1 -- spacer

  local solidLabel = frame:addLabel({ x = 1, y = y, width = w, height = 1, autoSize = false, text = "SOLID 0" })
  y = y + 1
  local solidDnBtn = frame:addButton({ x = 1, y = y, width = half, height = 1, text = "[-]" })
  local solidUpBtn = frame:addButton({ x = 1 + half, y = y, width = rest, height = 1, text = "[+]" })
  y = y + 1

  y = y + 1 -- spacer

  local liqLabel = frame:addLabel({ x = 1, y = y, width = w, height = 1, autoSize = false, text = "LIQ 0B" })
  y = y + 1
  local liqDnBtn = frame:addButton({ x = 1, y = y, width = half, height = 1, text = "[-]" })
  local liqUpBtn = frame:addButton({ x = 1 + half, y = y, width = rest, height = 1, text = "[+]" })
  y = y + 1

  backBtn:onClick(function() region:pop() end)
  solidDnBtn:onClick(function() M._setMax(runtime, "pump", -M.SOLID_STEP) end)
  solidUpBtn:onClick(function() M._setMax(runtime, "pump", M.SOLID_STEP) end)
  liqDnBtn:onClick(function() M._setMax(runtime, "tank", -M.LIQUID_STEP) end)
  liqUpBtn:onClick(function() M._setMax(runtime, "tank", M.LIQUID_STEP) end)

  -- apply(state): shows the current manual maxes from runtime.config ONLY.
  local function apply(_state)
    local cfg = runtime.config
    solidLabel:setText(fit("SOLID " .. tostring(cfg.fuel.pump.full or 0), w))
    local buckets = math.floor((cfg.fuel.tank.full or 0) / 1000 + 0.5)
    liqLabel:setText(fit("LIQ " .. buckets .. "B", w))
  end

  apply({})

  return {
    apply = apply,
    elements = {
      backBtn = backBtn,
      solidLabel = solidLabel, solidDnBtn = solidDnBtn, solidUpBtn = solidUpBtn,
      liqLabel = liqLabel, liqDnBtn = liqDnBtn, liqUpBtn = liqUpBtn,
    },
  }
end

return M
