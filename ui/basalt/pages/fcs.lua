-- ui/basalt/pages/fcs.lua
-- Standalone FCS cockpit page: the FLIGHT-graphical FCS region (ui/basalt/regions/fcs.lua) hosted
-- full-frame with a FULL border on a single monitor -- same composition as ui/basalt/pages/flight.lua's
-- bottom region, one region alone. The six status lines live behind the graphical PARAM drilldown
-- (the FLIGHT design); the master/coupling row + TRIM come from fcs_main. NO peripheral/Basalt access
-- at module load.
local Region    = require("ui.basalt.region")
local FcsRegion = require("ui.basalt.regions.fcs")

local M = {}
M.id = "fcs"
M.title = "FCS"

local FULL_EDGES = { top = true, bottom = true, left = true, right = true }

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local region
  local function onNav()
    runtime.uiRev = (runtime.uiRev or 0) + 1
    -- Edge the PARAMS watch (FCS cmd + NAV link), same as flight.lua's bottom region.
    require("ui.basalt.app").setParamsOpen(runtime, region:top() == "fcs_params")
  end
  region = Region.new(basalt, frame, {
    x = 1, y = 1, width = w, height = h, root = "fcs_main", onNav = onNav,
    screens = {
      fcs_main   = function(b, f, r) return FcsRegion.main(b, f, r, runtime, { edges = FULL_EDGES }) end,
      fcs_params = function(b, f, r) return FcsRegion.params(b, f, r, runtime, { edges = FULL_EDGES }) end,
    },
  })
  local function apply(state) region:apply(state) end
  return { id = M.id, apply = apply, elements = { region = region } }
end

return M
