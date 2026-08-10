package.path = "/?.lua;/?/init.lua;" .. package.path
local loaderui = require("fcs.boot.loaderui")
local assembled = loaderui.run()
if assembled then require("tools.flight") end
