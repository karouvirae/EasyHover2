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
local btnfit = require("ui.basalt.btnfit")

local M = {}

-- Manual-max stepper sizes: a stack (64) for the solid pump max, one bucket (1000 mB) for the
-- liquid tank max -- pinned constants so M.calfuel's onClick wiring and tests agree on the exact
-- delta without duplicating the literal. Task 4 adds fine (+/-1) and larger liquid batches
-- (50/100 buckets) so the calfuel screen can reach any max quickly without hundreds of taps.
M.SOLID_STEP  = 64
M.LIQUID_STEP = 1000
M.SOLID_FINE  = 1
M.LIQUID_50   = 50000
M.LIQUID_100  = 100000

-- Abbreviated fuel-source names for M.main's two gauge labels (Task 3 fuel-panel redesign).
M.SOLID_ABBR  = "BZC"
M.LIQUID_ABBR = "BDSL"

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

-- Standard round-half-up, used for the gauge bars' 0..100 progress value (Basalt's ProgressBar
-- clamps/floors internally, but we round here so e.g. 79.6% shows as 80 not 79).
local function round(x)
  return math.floor((x or 0) + 0.5)
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

-- ===== M.main ("emc_main"): flight-glance view, ~10 rows (Task 3 fuel-panel redesign) =====
--
-- Row 1 is a blank top margin (matches the merged page's other regions -- ui/basalt/regions/
-- fcs.lua's M.main); all content starts at internal y=2:
--   y2  "Solid Pump BZC"   label over the solid gauge (fit to width)
--   y3  <bar x=2..>  128x  green/gray ProgressBar (height 1) + right-justified int+unit value
--   y4  "Liquid Main BDSL" label (fit; falls back to "Liq Main BDSL" if the full text clips)
--   y5  <bar x=2..>  180B  same bar/value treatment, liquid units
--   y6  [ENG SW][PRIME]    height 1 (was 3), common width via ui.basalt.btnfit.grid
--   y7  blank
--   y8  MASTER light (1-char colored block + text) -- logic unchanged, shifted down
--   y9  FEED light -- unchanged, shifted
--   y10 CONFIG full-width drill -- unchanged, shifted
function M.main(basalt, frame, region, runtime)
  local w = ({ frame:getSize() })[1]

  -- Bar/value geometry, shared by both gauge rows: bar starts one column off the left border
  -- (x=2), a right-side value field (~5 cols: fits "9999x"/"9999B" etc) sits flush against the
  -- frame's right edge, with a 1-col gap between them. valLabel is built at this field's fixed
  -- width/x but apply() below re-sizes/re-positions it to the EXACT text length each call so the
  -- rendered text is genuinely right-justified against `valRight` (getText() itself stays
  -- unpadded -- easier to assert in tests and consistent with every other label in this module).
  local barX, gap, valW = 2, 1, 5
  local barW = math.max(1, w - (barX - 1) - gap - valW)
  local valX = barX + barW + gap
  local valRight = valX + valW - 1

  -- y2: solid gauge label.
  local pmpLabel = frame:addLabel({ x = 1, y = 2, width = w, height = 1, autoSize = false, text = fit("Solid Pump " .. M.SOLID_ABBR, w) })

  -- y3: solid gauge bar + value.
  local pmpBar = frame:addProgressBar({ x = barX, y = 3, width = barW, height = 1 })
  pmpBar:setProgressColor(colors.green)
  pmpBar:setBackground(colors.gray)
  local pmpValLabel = frame:addLabel({ x = valX, y = 3, width = valW, height = 1, autoSize = false, text = "" })

  -- y4: liquid gauge label -- fall back to the shorter "Liq Main" form if "Liquid Main <ABBR>"
  -- would clip against the frame width.
  local liquidFull  = "Liquid Main " .. M.LIQUID_ABBR
  local liquidShort = "Liq Main " .. M.LIQUID_ABBR
  local liquidText  = (#liquidFull > w) and liquidShort or liquidFull
  local mainLabel = frame:addLabel({ x = 1, y = 4, width = w, height = 1, autoSize = false, text = fit(liquidText, w) })

  -- y5: liquid gauge bar + value.
  local mainBar = frame:addProgressBar({ x = barX, y = 5, width = barW, height = 1 })
  mainBar:setProgressColor(colors.green)
  mainBar:setBackground(colors.gray)
  local mainValLabel = frame:addLabel({ x = valX, y = 5, width = valW, height = 1, autoSize = false, text = "" })

  -- y6: ENG SW / PRIME, height 1 (was 3), common width via btnfit.grid -- mirrors
  -- ui/basalt/regions/fcs.lua's M.main control-group geometry (Task 2).
  local ctrlGeo = btnfit.grid({ "ENG SW", "PRIME" }, { x0 = 1, availW = w, y0 = 6, gap = 1, align = "center" })
  local engSw = Switch.make(frame, { x = ctrlGeo[1].x, y = ctrlGeo[1].y, width = ctrlGeo[1].w, height = 1, text = "ENG SW" })
  local primeBtn = frame:addButton({ x = ctrlGeo[2].x, y = ctrlGeo[2].y, width = ctrlGeo[2].w, height = 1, text = "PRIME" })

  -- y7: spacer.

  -- y8: MASTER light (1-char colored block + short label).
  local lightY = 8
  local masterBlock = frame:addLabel({ x = 1, y = lightY, width = 1, height = 1, autoSize = false, text = " " })
  local masterText  = frame:addLabel({ x = 2, y = lightY, width = math.max(1, w - 1), height = 1, autoSize = false, text = "ENG OFF" })

  -- y9: FEED light.
  local feedY = lightY + 1
  local feedBlock = frame:addLabel({ x = 1, y = feedY, width = 1, height = 1, autoSize = false, text = " " })
  local feedText  = frame:addLabel({ x = 2, y = feedY, width = math.max(1, w - 1), height = 1, autoSize = false, text = "FEED no" })

  -- y10: CONFIG drill-in.
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

  -- Right-justify `text` (already fit to valW) against `valRight` by resizing/repositioning the
  -- label to the text's exact length -- see the geometry comment above.
  local function setVal(label, text)
    text = fit(text, valW)
    local tw = math.max(1, #text)
    label:setWidth(tw)
    label:setX(valRight - tw + 1)
    label:setText(text)
  end

  -- apply(state): idempotent repaint from `state` + runtime.config ONLY -- no peripheral polling.
  local function apply(state)
    state = state or {}
    local cfg = runtime.config

    pmpBar:setProgress(round(Fuel.manualFrac(state.pumpAmount, cfg.fuel.pump.full) * 100))
    setVal(pmpValLabel, tostring(state.pumpAmount or 0) .. "x")

    mainBar:setProgress(round(Fuel.manualFrac(state.tankMb, cfg.fuel.tank.full) * 100))
    setVal(mainValLabel, tostring(math.floor((state.tankMb or 0) / 1000)) .. "B")

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
      pmpLabel = pmpLabel, pmpBar = pmpBar, pmpValLabel = pmpValLabel,
      mainLabel = mainLabel, mainBar = mainBar, mainValLabel = mainValLabel,
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
  local y = 2 -- row 1 is a blank top margin, matching M.main's convention (Task 3/4).

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

-- ===== M.calfuel ("emc_calfuel"): manual max steppers, expanded (Task 4) =====
--
-- Top-margin convention (row 1 blank, content starts y=2 -- matches M.main/M.config):
--   y2  < BACK
--   y3  "SOLID <n>x" label
--   y4  solid decrements, centered via btnfit.grid: -64  -1
--   y5  solid increments, centered via btnfit.grid: +1  +64
--   y6  blank spacer
--   y7  "LIQ <n>B" label (n == buckets, i.e. mB/1000)
--   y8  liquid decrements, centered: -100  -50  -1   (captions are BUCKETS)
--   y9  liquid increments, centered: +1  +50  +100
-- 8 content rows total (y2..y9), well inside the ~11-row region.
function M.calfuel(basalt, frame, region, runtime)
  local w = ({ frame:getSize() })[1]
  local y = 2

  local backBtn = frame:addButton({ x = 1, y = y, width = w, height = 1, text = "< BACK" })
  y = y + 1

  -- SOLID group: label, then a decrements row and an increments row (fine +/-1, stack +/-64).
  local solidLabel = frame:addLabel({ x = 1, y = y, width = w, height = 1, autoSize = false, text = "" })
  y = y + 1

  local solidDnGeo = btnfit.grid({ "-64", "-1" }, { x0 = 1, availW = w, y0 = y, gap = 1, align = "center" })
  local solidDn64 = frame:addButton({ x = solidDnGeo[1].x, y = solidDnGeo[1].y, width = solidDnGeo[1].w, height = 1, text = "-64" })
  local solidDn1  = frame:addButton({ x = solidDnGeo[2].x, y = solidDnGeo[2].y, width = solidDnGeo[2].w, height = 1, text = "-1" })
  y = y + 1

  local solidUpGeo = btnfit.grid({ "+1", "+64" }, { x0 = 1, availW = w, y0 = y, gap = 1, align = "center" })
  local solidUp1  = frame:addButton({ x = solidUpGeo[1].x, y = solidUpGeo[1].y, width = solidUpGeo[1].w, height = 1, text = "+1" })
  local solidUp64 = frame:addButton({ x = solidUpGeo[2].x, y = solidUpGeo[2].y, width = solidUpGeo[2].w, height = 1, text = "+64" })
  y = y + 1

  y = y + 1 -- spacer

  -- LIQUID group: label, then a decrements row and an increments row. Captions are BUCKETS
  -- (matching the label's unit) but the wired deltas are mB -- 1 bucket == 1000 mB == M.LIQUID_STEP.
  local liqLabel = frame:addLabel({ x = 1, y = y, width = w, height = 1, autoSize = false, text = "" })
  y = y + 1

  local liqDnGeo = btnfit.grid({ "-100", "-50", "-1" }, { x0 = 1, availW = w, y0 = y, gap = 1, align = "center" })
  local liqDn100 = frame:addButton({ x = liqDnGeo[1].x, y = liqDnGeo[1].y, width = liqDnGeo[1].w, height = 1, text = "-100" })
  local liqDn50  = frame:addButton({ x = liqDnGeo[2].x, y = liqDnGeo[2].y, width = liqDnGeo[2].w, height = 1, text = "-50" })
  local liqDn1   = frame:addButton({ x = liqDnGeo[3].x, y = liqDnGeo[3].y, width = liqDnGeo[3].w, height = 1, text = "-1" })
  y = y + 1

  local liqUpGeo = btnfit.grid({ "+1", "+50", "+100" }, { x0 = 1, availW = w, y0 = y, gap = 1, align = "center" })
  local liqUp1   = frame:addButton({ x = liqUpGeo[1].x, y = liqUpGeo[1].y, width = liqUpGeo[1].w, height = 1, text = "+1" })
  local liqUp50  = frame:addButton({ x = liqUpGeo[2].x, y = liqUpGeo[2].y, width = liqUpGeo[2].w, height = 1, text = "+50" })
  local liqUp100 = frame:addButton({ x = liqUpGeo[3].x, y = liqUpGeo[3].y, width = liqUpGeo[3].w, height = 1, text = "+100" })
  y = y + 1

  backBtn:onClick(function() region:pop() end)

  solidDn64:onClick(function() M._setMax(runtime, "pump", -M.SOLID_STEP) end)
  solidDn1:onClick(function() M._setMax(runtime, "pump", -M.SOLID_FINE) end)
  solidUp1:onClick(function() M._setMax(runtime, "pump", M.SOLID_FINE) end)
  solidUp64:onClick(function() M._setMax(runtime, "pump", M.SOLID_STEP) end)

  liqDn100:onClick(function() M._setMax(runtime, "tank", -M.LIQUID_100) end)
  liqDn50:onClick(function() M._setMax(runtime, "tank", -M.LIQUID_50) end)
  liqDn1:onClick(function() M._setMax(runtime, "tank", -M.LIQUID_STEP) end)
  liqUp1:onClick(function() M._setMax(runtime, "tank", M.LIQUID_STEP) end)
  liqUp50:onClick(function() M._setMax(runtime, "tank", M.LIQUID_50) end)
  liqUp100:onClick(function() M._setMax(runtime, "tank", M.LIQUID_100) end)

  -- apply(state): shows the current manual maxes from runtime.config ONLY.
  local function apply(_state)
    local cfg = runtime.config
    local count = cfg.fuel.pump.full or 0
    solidLabel:setText(fit("SOLID " .. count .. "x", w))
    local buckets = math.floor((cfg.fuel.tank.full or 0) / 1000)
    liqLabel:setText(fit("LIQ " .. buckets .. "B", w))
  end

  apply({})

  return {
    apply = apply,
    elements = {
      backBtn = backBtn,
      solidLabel = solidLabel,
      solidDn64 = solidDn64, solidDn1 = solidDn1, solidUp1 = solidUp1, solidUp64 = solidUp64,
      liqLabel = liqLabel,
      liqDn100 = liqDn100, liqDn50 = liqDn50, liqDn1 = liqDn1,
      liqUp1 = liqUp1, liqUp50 = liqUp50, liqUp100 = liqUp100,
    },
  }
end

return M
