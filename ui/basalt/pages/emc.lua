-- ui/basalt/pages/emc.lua
-- Standalone EMC cockpit page: the FLIGHT-graphical EMC region (ui/basalt/regions/emc.lua) hosted
-- full-frame with a FULL border on a single monitor -- the same composition ui/basalt/pages/flight.lua
-- uses, but one region rather than an EMC-over-FCS stack. Reachable by default on an unassigned
-- monitor (ui/basalt/app.lua M.rootForMonitor defaults to "emc"). Drilldowns (CONFIG/CAL FUEL) come
-- from the region itself. NO peripheral/Basalt access at module load.
local Region    = require("ui.basalt.region")
local EmcRegion = require("ui.basalt.regions.emc")

local M = {}
M.id = "emc"
M.title = "EMC"

local FULL_EDGES = { top = true, bottom = true, left = true, right = true }

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local function bump() runtime.uiRev = (runtime.uiRev or 0) + 1 end
  local region = Region.new(basalt, frame, {
    x = 1, y = 1, width = w, height = h, root = "emc_main", onNav = bump,
    screens = {
      emc_main    = function(b, f, r) return EmcRegion.main(b, f, r, runtime, { edges = FULL_EDGES }) end,
      emc_config  = function(b, f, r) return EmcRegion.config(b, f, r, runtime, { edges = FULL_EDGES }) end,
      emc_calfuel = function(b, f, r) return EmcRegion.calfuel(b, f, r, runtime, { edges = FULL_EDGES }) end,
    },
  })
  local function apply(state) region:apply(state) end
  return { id = M.id, apply = apply, elements = { region = region } }
end

return M
