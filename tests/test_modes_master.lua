-- tests/test_modes_master.lua
local t = require("tests.framework")
local Master = require("fcs.modes.master")

t.test("master registry: CPL arrests drift, DCPL coasts, default CPL", function()
  t.eq(Master.default, "CPL", "default master")
  t.eq(#Master.MASTERS, 2, "two masters")
  t.eq(Master.MASTERS[1], "CPL", "order CPL first")
  t.eq(Master.MASTERS[2], "DCPL", "order DCPL second")
  t.eq(Master.byId.CPL.driftArrest, true, "CPL arrests")
  t.eq(Master.byId.DCPL.driftArrest, false, "DCPL coasts")
  t.eq(Master.byId.CPL.id, "CPL", "id carried")
end)
