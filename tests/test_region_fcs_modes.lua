-- tests/test_region_fcs_modes.lua
-- Two independent exclusive chip groups on the merged flight page's FCS region
-- (ui/basalt/regions/fcs.lua's fcs_main screen): 5 flight-mode chips (PRECISION/MAN/CRUISE/LDG/DRN,
-- in modeCtrls) + 2 master-mode chips (CPL/DCPL, in masterCtrls). Chips wrap 3-then-2 across rows
-- with short ASCII labels (ui.panels.fcs's MODE_LABEL/MASTER_LABEL) -- covered by a FIT CHECK
-- against an explicit small/narrow frame, not the wide headless terminal (see
-- tests/test_bitconfig_tuning.lua's "every screen must fit a REALISTIC monitor" regression for the
-- same convention).
local t = require("tests.framework")
local FcsRegion = require("ui.basalt.regions.fcs")
local Region = require("ui.basalt.region")
local BasaltApp = require("ui.basalt.app")

local function stubRuntime(latest)
  local sent = {}
  return {
    sent = sent,
    rx = { latest = function() return latest end },
    sender = { send = function(_, cmd) return cmd end },
    links = { tel = { send = function(_, frame) sent[#sent + 1] = frame end } },
  }, sent
end

t.test("region exposes the mode selector wiring, five flight modes + two master modes", function()
  -- The region builds from ui.panels.fcs; assert the shared contract is used.
  local F = require("ui.panels.fcs")
  t.eq(#F.MODES, 5, "region selector uses the shared 5-mode flight list (PRECISION/MAN/CRUISE/LDG/DRN)")
  t.eq(#F.MASTERS, 2, "region master selector uses the shared 2-mode master list (CPL/DCPL)")
  t.truthy(FcsRegion.main, "region module loads and exposes main()")
end)

t.test("fcs_main: masterCtrls hold CPL/DCPL, modeCtrls hold PRE/MAN/CRU (+LDG/DRN), every chip fits the real 36x21 region", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local rt = stubRuntime({ engaged = false, gndSafety = false, mode = "GROUND" })
  local r = Region.new(basalt, parent, {
    x = 1, y = 1, width = 36, height = 21, root = "fcs_main",   -- real FCS region (flight M.split botH)
    screens = {
      fcs_main   = function(b, f, rg) return FcsRegion.main(b, f, rg, rt) end,
      fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end,
    },
  })

  r:apply({ engaged = false, gndSafety = false })

  local rec = r.built.fcs_main
  t.truthy(rec ~= nil, "fcs_main built")
  -- modeCtrls holds the flight modes (sub-region 3); masterCtrls holds CPL/DCPL (sub-region 2) -- two
  -- independent exclusive groups now.
  local modeCtrls = rec.handle.elements.modeCtrls
  local masterCtrls = rec.handle.elements.masterCtrls

  t.truthy(modeCtrls.PRECISION ~= nil, "PRECISION chip present")
  t.truthy(modeCtrls.MAN ~= nil, "MAN chip present")
  t.truthy(modeCtrls.CRUISE ~= nil, "CRUISE chip present")
  t.truthy(modeCtrls.LDG ~= nil, "LDG chip present")
  t.truthy(modeCtrls.DRN ~= nil, "DRN chip present")
  t.truthy(masterCtrls ~= nil, "masterCtrls table exported")
  t.truthy(masterCtrls.CPL ~= nil, "CPL chip present in masterCtrls")
  t.truthy(masterCtrls.DCPL ~= nil, "DCPL chip present in masterCtrls")

  -- FIT CHECK against the region's own child frame (36 cols wide). Mode/master chips are chipButton
  -- controls -- their placed element is .label (a raw button); no chip may overshoot the frame width.
  local frameW = rec.frame:getSize()
  t.eq(frameW, 36, "sanity: the region's child frame is the real 36-col size")

  for _, group in ipairs({ modeCtrls, masterCtrls }) do
    for id, sw in pairs(group) do
      local ex, ew = sw.label:getX(), sw.label:getWidth()
      t.truthy(ex + ew - 1 <= frameW,
        id .. " chip overshoots the frame width: x=" .. tostring(ex) .. " width=" .. tostring(ew) ..
        " frameW=" .. tostring(frameW))
    end
  end

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("MASTER_LABEL.DCPL is the full DCPL label, not the old DCP abbreviation", function()
  local F = require("ui.panels.fcs")
  t.eq(F.MASTER_LABEL.DCPL, "DCPL", "DCPL label reads DCPL, not DCP")
end)

t.test("fcs_main: top margin + overshoot fit, and each group's chips share one common width (36x21)", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local rt = stubRuntime({ engaged = false, gndSafety = false, mode = "GROUND" })
  local r = Region.new(basalt, parent, {
    x = 1, y = 1, width = 36, height = 21, root = "fcs_main",
    screens = {
      fcs_main   = function(b, f, rg) return FcsRegion.main(b, f, rg, rt) end,
      fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end,
    },
  })

  r:apply({ engaged = false, gndSafety = false })

  local rec = r.built.fcs_main
  local els = rec.handle.elements
  local frameW = rec.frame:getSize()
  t.eq(frameW, 36, "sanity: real 36-col frame")

  -- Collect every placed control/mode/trim element for the margin + overshoot checks. FCS/GND/PARAM
  -- are raw ctrlButtons; the mode + trim chips are chipButton controls placed via .label.
  local placed = {}
  placed[#placed + 1] = { name = "fcs", btn = els.fcsBtn }
  placed[#placed + 1] = { name = "gnd", btn = els.gndBtn }
  placed[#placed + 1] = { name = "params", btn = els.paramBtn }
  for id, sw in pairs(els.modeCtrls) do placed[#placed + 1] = { name = "mode:" .. id, btn = sw.label } end
  for id, sw in pairs(els.masterCtrls) do placed[#placed + 1] = { name = "master:" .. id, btn = sw.label } end
  t.truthy(els.trimCtrl ~= nil, "trim toggle present in elements")
  placed[#placed + 1] = { name = "trim", btn = els.trimCtrl.label }

  for _, p in ipairs(placed) do
    local ey, ex, ew = p.btn:getY(), p.btn:getX(), p.btn:getWidth()
    t.truthy(ey >= 2, p.name .. " must sit below the row-1 blank top margin, got y=" .. tostring(ey))
    t.truthy(ex + ew - 1 <= 36, p.name .. " overshoots the 36-col frame: x=" .. tostring(ex) .. " w=" .. tostring(ew))
  end

  -- FCS/GND share one common width; PARAM is deliberately a touch wider for its longer label.
  t.eq(els.gndBtn:getWidth(), els.fcsBtn:getWidth(), "gnd shares fcs's width")
  t.truthy(els.paramBtn:getWidth() >= els.fcsBtn:getWidth(), "PARAM is at least as wide as FCS/GND")

  -- The 5 flight chips share one common width (in modeCtrls).
  local modeW
  for _, id in ipairs({ "PRECISION", "MAN", "CRUISE", "LDG", "DRN" }) do
    local w = els.modeCtrls[id].label:getWidth()
    if not modeW then modeW = w end
    t.eq(w, modeW, id .. " shares the common mode-group width")
  end

  -- The 2 master chips share one common width (in masterCtrls) -- an independent group from modeCtrls.
  local masterW
  for _, id in ipairs({ "CPL", "DCPL" }) do
    local w = els.masterCtrls[id].label:getWidth()
    if not masterW then masterW = w end
    t.eq(w, masterW, id .. " shares the common master-group width")
  end

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("trim toggle: no-optimistic-UI, gated by FcsPanel.trimActive, labelled TRIM UP/DN/--", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local rt = stubRuntime({})
  local r = Region.new(basalt, parent, {
    x = 1, y = 1, width = 36, height = 21, root = "fcs_main",
    screens = {
      fcs_main   = function(b, f, rg) return FcsRegion.main(b, f, rg, rt) end,
      fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end,
    },
  })

  r:apply({ masterMode = "CPL", trimDir = 1 })
  local trimCtrl = r.built.fcs_main.handle.elements.trimCtrl
  t.eq(trimCtrl.label:getText(), "TRIM UP", "coupled + trimDir>0 -> TRIM UP")

  r:apply({ flightMode = "PRECISION" })
  t.eq(trimCtrl.label:getText(), "TRIM --", "uncoupled mode -> disabled TRIM --")
end)

t.test("fcs_main (Task 11): DRN + LDG are real clickable radio chips; only TRK remains a placeholder", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local rt, sent = stubRuntime({ engaged = false, gndSafety = false, mode = "GROUND" })
  local r = Region.new(basalt, parent, {
    x = 1, y = 1, width = 36, height = 21, root = "fcs_main",
    screens = {
      fcs_main   = function(b, f, rg) return FcsRegion.main(b, f, rg, rt) end,
      fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end,
    },
  })

  r:apply({ engaged = false, gndSafety = false })

  local built = r.built.fcs_main
  local els = built.handle.elements

  t.truthy(els.modeCtrls.LDG, "LDG chip registered")
  t.truthy(els.modeCtrls.DRN, "DRN chip registered")

  -- Click == fire the same "mouse_click" event :onClick(fn) registered a listener under (mirrors
  -- test_region_emc.lua's construction-probe click idiom).
  local function click(ctrl) ctrl.label:fireEvent("mouse_click", 1, 1, 1) end

  click(els.modeCtrls.LDG)
  t.eq(sent[#sent].k, "flightMode", "LDG click sends a flightMode command")
  t.eq(sent[#sent].id, "LDG", "LDG click sends id=LDG")

  click(els.modeCtrls.DRN)
  t.eq(sent[#sent].k, "flightMode", "DRN click sends a flightMode command")
  t.eq(sent[#sent].id, "DRN", "DRN click sends id=DRN")

  -- Only ONE placeholder remains: TRK. NOL is gone.
  t.eq(#els.placeholders, 1, "only one placeholder remains")
  t.eq(els.placeholders[1].label:getText(), "TRK", "the sole remaining placeholder is TRK")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("fcs_main: missing-FCS blink cue drives the OUTLINE only (mode-chip border toggles, chip untouched)", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local rt = stubRuntime({ engaged = true, gndSafety = false, mode = "PRECISION" })
  local r = Region.new(basalt, parent, {
    x = 1, y = 1, width = 36, height = 21, root = "fcs_main",
    screens = { fcs_main = function(b, f, rg) return FcsRegion.main(b, f, rg, rt) end,
                fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end },
  })
  -- Healthy: mode chips carry NO outline (regression guard for the always-on-border bug), FCS/GND show
  -- their feedback-colour border, chip keeps its live green/red. (apply() lazily builds fcs_main first.)
  r:apply({ fcsStale = false, engaged = true, gndSafety = false, flightMode = "PRECISION" })
  local els = r.built.fcs_main.handle.elements
  local cpl = els.masterCtrls.CPL
  t.eq(cpl.chip.get("borderTop"), false, "healthy: mode chip has NO outline")
  t.eq(els.fcsBtn.get("borderColor"), colors.green, "healthy: FCS border = engaged green")

  -- Stale, red phase: all three groups' outline blinks to red; the mode chip's bar bg is unchanged.
  r:apply({ fcsStale = true, blinkPhase = 1, engaged = true, gndSafety = false, flightMode = "PRECISION" })
  t.eq(cpl.chip.get("borderTop"), true, "stale: mode chip outline present")
  t.eq(cpl.chip.get("borderColor"), colors.red, "stale red phase: outline red")
  t.eq(els.fcsBtn.get("borderColor"), colors.red, "stale red phase: FCS outline red (not engaged green)")

  -- Stale, gray phase: outline blinks to the inert gray.
  r:apply({ fcsStale = true, blinkPhase = 0, engaged = true, gndSafety = false, flightMode = "PRECISION" })
  t.eq(cpl.chip.get("borderColor"), colors.gray, "stale gray phase: outline gray")

  -- Recover: outline removed again on the mode chips.
  r:apply({ fcsStale = false, engaged = true, gndSafety = false, flightMode = "PRECISION" })
  t.eq(cpl.chip.get("borderTop"), false, "recovered: mode chip outline removed again")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "render clean: " .. tostring(err))
end)
