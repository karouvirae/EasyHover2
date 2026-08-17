package.path = "/?.lua;/?/init.lua;" .. package.path
local loaderui = require("fcs.boot.loaderui")
local assembled, logging = loaderui.run()
if assembled then
  -- Boot-chosen logging: tools/flight.lua reads _G.EH2_FLIGHTLOG (same hook the `fcslog` launcher
  -- sets). Y at the "Enable FCS logging?" prompt -> instrumentation + P-to-upload for this instance.
  _G.EH2_FLIGHTLOG = logging == true
  require("tools.flight")
end
