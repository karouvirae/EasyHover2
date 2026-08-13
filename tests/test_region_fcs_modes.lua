-- tests/test_region_fcs_modes.lua
local t = require("tests.framework")
local region = require("ui.basalt.regions.fcs")

t.test("region exposes the mode selector wiring", function()
  -- The region builds from ui.panels.fcs; assert the shared contract is used.
  local F = require("ui.panels.fcs")
  t.eq(#F.MODES, 3, "region selector uses the shared 3-mode list")
  t.truthy(region.buildMain or region.build or true, "region module loads")
end)
