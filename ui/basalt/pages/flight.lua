-- ui/basalt/pages/flight.lua
-- The merged flight page for the overhead 1x2 monitors: a compact EMC view stacked over a compact
-- FCS view in ONE frame, but as two INDEPENDENT regions -- each has its own nav stack, so drilling
-- one half (EMC config / CAL FUEL, or FCS params) never touches the other. Content-based split (the
-- boundary is not the block seam); every region screen is compact enough to fit its rows.
--
-- Standalone emc/fcs/config/ap/nav pages are untouched; this is an ADDITIONAL page (id "flight").
local Region    = require("ui.basalt.region")
local EmcRegion = require("ui.basalt.regions.emc")
local FcsRegion = require("ui.basalt.regions.fcs")

local M = {}
M.id = "flight"
M.title = "FLIGHT"

-- Pure: how the frame's rows split between the top (EMC) and bottom (FCS) regions. EMC's glance
-- view wants ~11 rows; give it ~46% (min 9) and hand the rest to FCS, which fills its slack with
-- MODE placeholders. Returned as { topH, botH } with topH+botH == h.
function M.split(h)
  local topH = math.max(9, math.floor(h * 0.46))
  if topH > h - 4 then topH = math.max(1, h - 4) end   -- always leave FCS at least a few rows
  return topH, h - topH
end

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local topH, botH = M.split(h)

  -- A region nav change (CONFIG/CAL FUEL/PARAMS/BACK) isn't a frame-level nav change, so bump uiRev
  -- to wake the dirty-gated render loop and let the region swap its visible screen next tick.
  local function bump() runtime.uiRev = (runtime.uiRev or 0) + 1 end

  local top = Region.new(basalt, frame, {
    x = 1, y = 1, width = w, height = topH, root = "emc_main", onNav = bump,
    screens = {
      emc_main    = function(b, f, r) return EmcRegion.main(b, f, r, runtime) end,
      emc_config  = function(b, f, r) return EmcRegion.config(b, f, r, runtime) end,
      emc_calfuel = function(b, f, r) return EmcRegion.calfuel(b, f, r, runtime) end,
    },
  })

  local bottom = Region.new(basalt, frame, {
    x = 1, y = topH + 1, width = w, height = botH, root = "fcs_main", onNav = bump,
    screens = {
      fcs_main   = function(b, f, r) return FcsRegion.main(b, f, r, runtime) end,
      fcs_params = function(b, f, r) return FcsRegion.params(b, f, r, runtime) end,
    },
  })

  local function apply(state)
    top:apply(state)
    bottom:apply(state)
  end

  return { id = M.id, apply = apply, elements = { top = top, bottom = bottom } }
end

return M
