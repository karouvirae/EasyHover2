-- fcs/schemes/decoupled.lua -- DCPL: CPL with horizontal drift-arrest OFF (momentum coasts).
local Coupled = require("fcs.schemes.coupled")
local M = {}
function M.new(cfg) return Coupled.new(cfg, { decoupled = true }) end
return M
