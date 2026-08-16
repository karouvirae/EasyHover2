package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local F = require("tools.fcs2disk")

local KINDS = { "devbind", "senscal", "tuning" }

t.test("plan: all three present with a mount -> write all three, none missing", function()
  local r = F.plan({ present = { devbind = true, senscal = true, tuning = true }, mount = "disk" })
  t.eq(r.action, "write")
  t.eq(#r.kinds, 3); t.eq(#r.missing, 0)
  for i, k in ipairs(KINDS) do t.eq(r.kinds[i], k) end
end)

t.test("plan: some present -> writes present, lists missing (in cfgspec order)", function()
  local r = F.plan({ present = { devbind = true, tuning = true }, mount = "disk" })
  t.eq(r.action, "write")
  t.eq(#r.kinds, 2); t.eq(r.kinds[1], "devbind"); t.eq(r.kinds[2], "tuning")
  t.eq(#r.missing, 1); t.eq(r.missing[1], "senscal")
end)

t.test("plan: no mount -> no-mount action regardless of presence", function()
  t.eq(F.plan({ present = { devbind = true }, mount = nil }).action, "no-mount")
end)

t.test("plan: mount present but nothing local -> abort", function()
  t.eq(F.plan({ present = {}, mount = "disk" }).action, "abort")
end)
