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

t.test("fcs_main: modeSwitches include CPL/DCPL, and the whole row fits a real 14x12 region (FIT CHECK)", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local rt = stubRuntime({ engaged = false, gndSafety = false, mode = "GROUND" })
  local r = Region.new(basalt, parent, {
    x = 1, y = 1, width = 14, height = 12, root = "fcs_main",
    screens = {
      fcs_main   = function(b, f, rg) return FcsRegion.main(b, f, rg, rt) end,
      fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end,
    },
  })

  r:apply({ engaged = false, gndSafety = false })

  local rec = r.built.fcs_main
  t.truthy(rec ~= nil, "fcs_main built")
  local modeSwitches = rec.handle.elements.modeSwitches

  t.truthy(modeSwitches.PRECISION ~= nil, "PRECISION switch present")
  t.truthy(modeSwitches.MAN ~= nil, "MAN switch present")
  t.truthy(modeSwitches.CRUISE ~= nil, "CRUISE switch present")
  t.truthy(modeSwitches.CPL ~= nil, "CPL switch present")
  t.truthy(modeSwitches.DCPL ~= nil, "DCPL switch present")

  -- FIT CHECK (config-UI-overhaul lesson): assert against the SMALL/narrow region frame (14 cols
  -- wide, matching Region.new's own width=14 above) -- NOT the wide headless terminal. rec.frame is
  -- the region's own child frame, sized exactly to that width/height (ui/basalt/region.lua:showTop).
  -- Bound is the FULL frame width (btnfit.grid's availW=w convention -- Task 2 dropped the old
  -- 1-col left/right inset in favour of a row-1-only top margin), not frameW-1.
  local frameW, frameH = rec.frame:getSize()
  t.eq(frameW, 14, "sanity: the region's child frame really is the narrow 14-col size")

  for id, sw in pairs(modeSwitches) do
    local ex, ew = sw.button:getX(), sw.button:getWidth()
    t.truthy(ex + ew - 1 <= frameW,
      id .. " switch overshoots the frame width: x=" .. tostring(ex) .. " width=" .. tostring(ew) ..
      " frameW=" .. tostring(frameW))
  end

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("MODE_LABEL.DCPL is the full DCPL label, not the old DCP abbreviation", function()
  local F = require("ui.panels.fcs")
  t.eq(F.MODE_LABEL.DCPL, "DCPL", "DCPL label reads DCPL, not DCP")
end)

t.test("fcs_main: top margin, btnfit-centered groups, and trim toggle all fit a 14x13 region", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local rt = stubRuntime({ engaged = false, gndSafety = false, mode = "GROUND" })
  local r = Region.new(basalt, parent, {
    x = 1, y = 1, width = 14, height = 13, root = "fcs_main",
    screens = {
      fcs_main   = function(b, f, rg) return FcsRegion.main(b, f, rg, rt) end,
      fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end,
    },
  })

  r:apply({ engaged = false, gndSafety = false })

  local rec = r.built.fcs_main
  local els = rec.handle.elements
  local frameW, frameH = rec.frame:getSize()
  t.eq(frameW, 14, "sanity: narrow 14-col frame")

  -- Collect every placed control/mode/trim element for the margin + overshoot checks.
  local placed = {}
  placed[#placed + 1] = { name = "fcs", btn = els.switches.fcs.button }
  placed[#placed + 1] = { name = "gnd", btn = els.switches.gnd.button }
  placed[#placed + 1] = { name = "params", btn = els.paramsBtn }
  for id, sw in pairs(els.modeSwitches) do placed[#placed + 1] = { name = "mode:" .. id, btn = sw.button } end
  t.truthy(els.trimBtn ~= nil, "trim toggle present in elements")
  placed[#placed + 1] = { name = "trim", btn = els.trimBtn.button }

  for _, p in ipairs(placed) do
    local ey, ex, ew = p.btn:getY(), p.btn:getX(), p.btn:getWidth()
    t.truthy(ey >= 2, p.name .. " must sit below the row-1 blank top margin, got y=" .. tostring(ey))
    t.truthy(ex + ew - 1 <= 14, p.name .. " overshoots the 14-col frame: x=" .. tostring(ex) .. " w=" .. tostring(ew))
  end

  -- FCS/GND/PARM group shares one common width.
  local fcsW = els.switches.fcs.button:getWidth()
  t.eq(els.switches.gnd.button:getWidth(), fcsW, "gnd shares fcs's width")
  t.eq(els.paramsBtn:getWidth(), fcsW, "params shares fcs's width")

  -- The 5 mode buttons share one common width.
  local modeW
  for _, id in ipairs({ "PRECISION", "MAN", "CRUISE", "CPL", "DCPL" }) do
    local w = els.modeSwitches[id].button:getWidth()
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
    x = 1, y = 1, width = 14, height = 13, root = "fcs_main",
    screens = {
      fcs_main   = function(b, f, rg) return FcsRegion.main(b, f, rg, rt) end,
      fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end,
    },
  })

  r:apply({ flightMode = "CPL", trimDir = 1 })
  local trimBtn = r.built.fcs_main.handle.elements.trimBtn
  t.eq(trimBtn.button:getText(), "TRIM UP", "coupled + trimDir>0 -> TRIM UP")

  r:apply({ flightMode = "PRECISION" })
  t.eq(trimBtn.button:getText(), "TRIM --", "uncoupled mode -> disabled TRIM --")
end)
