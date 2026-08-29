-- fcs/modes/master.lua -- the master-mode registry. Master mode is orthogonal to flight mode:
-- exactly one is always active. It owns ONE thing -- the hands-off horizontal drift law --
-- exposed as driftArrest (CPL = hold station / arrest residual velocity; DCPL = coast). It also
-- gates the always-applied forward trim (see fcs/runtime/loop.lua), identical in both modes.
local M = {
  MASTERS = { "CPL", "DCPL" },
  default = "CPL",
  byId = {
    CPL  = { id = "CPL",  driftArrest = true  },
    DCPL = { id = "DCPL", driftArrest = false },
  },
}
return M
