package.path = "/?.lua;/?/init.lua;" .. package.path
local loaderui = require("fcs.boot.loaderui")
local assembled = loaderui.run()
if assembled then shell.run("/launchers/flight.lua") end
