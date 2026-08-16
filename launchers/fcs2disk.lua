package.path = "/?.lua;/?/init.lua;" .. package.path
-- launchers/fcs2disk.lua
-- Dump the FCS's local split configs onto the shared disk for the UI PC's DTC to import.
local fcs2disk = require("tools.fcs2disk")
print("== EH2 FCS -> DISK ==")
print(fcs2disk.run())
