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
  local frameW, frameH = rec.frame:getSize()
  t.eq(frameW, 14, "sanity: the region's child frame really is the narrow 14-col size")

  for id, sw in pairs(modeSwitches) do
    local ex, ew = sw.button:getX(), sw.button:getWidth()
    t.truthy(ex + ew - 1 <= frameW - 1,
      id .. " switch overshoots the interior width: x=" .. tostring(ex) .. " width=" .. tostring(ew) ..
      " frameW=" .. tostring(frameW))
  end

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)
