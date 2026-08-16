package.path = "/?.lua;/?/init.lua;" .. package.path
-- launchers/splitconfig.lua
-- Run the legacy-config split migration on the FCS.
local splitconfig = require("tools.splitconfig")
print("== EH2 SPLIT CONFIG ==")
print(splitconfig.run())
