-- tests/test_region_fcs_modes.lua
-- 5-mode selector (PRECISION/MAN/CRUISE/CPL/DCPL) on the merged flight page's FCS region
-- (ui/basalt/regions/fcs.lua's fcs_main screen). 5 switches no longer fit one row on the region's
-- ~14-col width, so the region wraps them 3-then-2 across two rows with short ASCII labels
-- (ui.panels.fcs's MODE_LABEL) -- covered by a FIT CHECK against an explicit small/narrow frame,
-- not the wide headless terminal (see tests/test_bitconfig_tuning.lua's "every screen must fit a
-- REALISTIC monitor" regression for the same convention).
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

t.test("region exposes the mode selector wiring, five modes", function()
  -- The region builds from ui.panels.fcs; assert the shared contract is used.
  local F = require("ui.panels.fcs")
  t.eq(#F.MODES, 5, "region selector uses the shared 5-mode list (PRECISION/MAN/CRUISE/CPL/DCPL)")
  t.truthy(FcsRegion.main, "region module loads and exposes main()")
end)

t.test("fcs_main: modeCtrls include CPL/DCPL + PRE/MAN/CRU, and every chip fits the real 36x21 region", function()
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
  -- modeCtrls holds ALL real modes: master CPL/DCPL (sub-region 2) + flight PRE/MAN/CRU (sub-region 3).
  local modeCtrls = rec.handle.elements.modeCtrls

  t.truthy(modeCtrls.PRECISION ~= nil, "PRECISION chip present")
  t.truthy(modeCtrls.MAN ~= nil, "MAN chip present")
  t.truthy(modeCtrls.CRUISE ~= nil, "CRUISE chip present")
  t.truthy(modeCtrls.CPL ~= nil, "CPL chip present")
  t.truthy(modeCtrls.DCPL ~= nil, "DCPL chip present")

  -- FIT CHECK against the region's own child frame (36 cols wide). Mode chips are chipButton controls
  -- -- their placed element is .label (a raw button); no chip may overshoot the frame width.
  local frameW = rec.frame:getSize()
  t.eq(frameW, 36, "sanity: the region's child frame is the real 36-col size")

  for id, sw in pairs(modeCtrls) do
    local ex, ew = sw.label:getX(), sw.label:getWidth()
    t.truthy(ex + ew - 1 <= frameW,
      id .. " chip overshoots the frame width: x=" .. tostring(ex) .. " width=" .. tostring(ew) ..
      " frameW=" .. tostring(frameW))
  end

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("MODE_LABEL.DCPL is the full DCPL label, not the old DCP abbreviation", function()
  local F = require("ui.panels.fcs")
  t.eq(F.MODE_LABEL.DCPL, "DCPL", "DCPL label reads DCPL, not DCP")
end)

t.test("fcs_main: top margin + overshoot fit, and the 5 mode chips share one common width (36x21)", function()
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

  -- The 5 mode chips share one common width.
  local modeW
  for _, id in ipairs({ "PRECISION", "MAN", "CRUISE", "CPL", "DCPL" }) do
    local w = els.modeCtrls[id].label:getWidth()
    if not modeW then modeW = w end
    t.eq(w, modeW, id .. " shares the common mode-group width")
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

  r:apply({ flightMode = "CPL", trimDir = 1 })
  local trimCtrl = r.built.fcs_main.handle.elements.trimCtrl
  t.eq(trimCtrl.label:getText(), "TRIM UP", "coupled + trimDir>0 -> TRIM UP")

  r:apply({ flightMode = "PRECISION" })
  t.eq(trimCtrl.label:getText(), "TRIM --", "uncoupled mode -> disabled TRIM --")
end)

t.test("fcs_main: apply with fcsStale (missing-FCS blink cue) renders without error, both phases", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local rt = stubRuntime({ engaged = true, gndSafety = false, mode = "PRECISION" })
  local r = Region.new(basalt, parent, {
    x = 1, y = 1, width = 36, height = 21, root = "fcs_main",
    screens = { fcs_main = function(b, f, rg) return FcsRegion.main(b, f, rg, rt) end,
                fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end },
  })
  -- stale, red phase; stale, gray phase; then healthy again -- each must apply + render clean.
  for _, st in ipairs({ { fcsStale = true, blinkPhase = 1, engaged = true, flightMode = "PRECISION" },
                        { fcsStale = true, blinkPhase = 0, engaged = true, flightMode = "PRECISION" },
                        { fcsStale = false, engaged = true, flightMode = "PRECISION" } }) do
    local ok, err = pcall(function() r:apply(st); basalt.update("timer", -1) end)
    t.truthy(ok, "apply/render clean for fcsStale=" .. tostring(st.fcsStale) .. " phase=" .. tostring(st.blinkPhase) .. ": " .. tostring(err))
  end
end)
