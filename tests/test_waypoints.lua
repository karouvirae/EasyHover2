-- tests/test_waypoints.lua
-- Pure NAV waypoint/route store (nav/waypoints.lua): the model + CRUD + validation + persistence
-- that lives on the NAV PC. No Basalt/peripherals (load/save use fs, exercised headless).
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local W = require("nav.waypoints")

-- ---- schema / types ----
t.test("defaults is an empty store; withDefaults fills missing keys", function()
  local d = W.defaults()
  t.eq(type(d.waypoints), "table"); t.eq(#d.waypoints, 0)
  t.eq(type(d.routes), "table"); t.eq(#d.routes, 0)
  local m = W.withDefaults({ waypoints = { { name = "A", x = 1, y = 2, z = 3, type = "base" } } })
  t.eq(#m.waypoints, 1); t.eq(type(m.routes), "table")
end)

t.test("TYPES is the fixed vocabulary; isType guards it", function()
  t.eq(#W.TYPES, 4)
  t.truthy(W.isType("base") and W.isType("outpost") and W.isType("facility") and W.isType("poi"))
  t.eq(W.isType("banana"), false)
  t.eq(W.isType(nil), false)
end)

-- ---- waypoint CRUD ----
t.test("addWpt validates and appends; rejects bad input and duplicate names", function()
  local s = W.defaults()
  local wpt, err = W.addWpt(s, { name = "Home", x = 10, y = -47, z = 20, type = "base" })
  t.truthy(wpt ~= nil and err == nil); t.eq(#s.waypoints, 1)
  t.eq(W.addWpt(s, { name = "", x = 1, y = 1, z = 1, type = "base" }), nil, "empty name rejected")
  t.eq(W.addWpt(s, { name = "X", x = "no", y = 1, z = 1, type = "base" }), nil, "non-number coord rejected")
  t.eq(W.addWpt(s, { name = "X", x = 1, y = 1, z = 1, type = "nope" }), nil, "bad type rejected")
  t.eq(W.addWpt(s, { name = "Home", x = 1, y = 1, z = 1, type = "poi" }), nil, "duplicate name rejected")
  t.eq(#s.waypoints, 1, "no bad/dup waypoint was added")
end)

t.test("find / editWpt / deleteWpt operate by name", function()
  local s = W.defaults()
  W.addWpt(s, { name = "Home", x = 10, y = -47, z = 20, type = "base" })
  t.truthy(W.find(s, "Home") ~= nil); t.eq(W.find(s, "Nope"), nil)
  t.truthy(W.editWpt(s, "Home", { y = 5, type = "outpost" }))
  local h = W.find(s, "Home"); t.eq(h.y, 5); t.eq(h.type, "outpost"); t.eq(h.x, 10)
  t.eq(W.editWpt(s, "Ghost", { y = 1 }), nil, "edit of a missing name fails")
  t.truthy(W.deleteWpt(s, "Home")); t.eq(#s.waypoints, 0)
  t.eq(W.deleteWpt(s, "Home"), nil, "delete of a missing name fails")
end)

t.test("filter returns a type's waypoints, or all when type is nil/all", function()
  local s = W.defaults()
  W.addWpt(s, { name = "A", x = 1, y = 1, z = 1, type = "base" })
  W.addWpt(s, { name = "B", x = 2, y = 2, z = 2, type = "poi" })
  W.addWpt(s, { name = "C", x = 3, y = 3, z = 3, type = "base" })
  t.eq(#W.filter(s, "base"), 2)
  t.eq(#W.filter(s, "poi"), 1)
  t.eq(#W.filter(s, nil), 3); t.eq(#W.filter(s, "all"), 3)
  -- stable insertion order
  t.eq(W.filter(s, "base")[1].name, "A"); t.eq(W.filter(s, "base")[2].name, "C")
end)

-- ---- merge (used by disk import) ----
t.test("mergeWpts adds new and replaces same-name (dedupe by name)", function()
  local s = W.defaults()
  W.addWpt(s, { name = "A", x = 1, y = 1, z = 1, type = "base" })
  W.mergeWpts(s, { { name = "A", x = 9, y = 9, z = 9, type = "poi" },   -- replaces A
                   { name = "B", x = 2, y = 2, z = 2, type = "outpost" } }) -- new
  t.eq(#s.waypoints, 2)
  t.eq(W.find(s, "A").x, 9); t.eq(W.find(s, "A").type, "poi")
  t.truthy(W.find(s, "B") ~= nil)
end)

-- ---- persistence ----
t.test("save then load round-trips the store", function()
  local path = "/eh2_nav_wpt_test.tbl"
  if fs.exists(path) then fs.delete(path) end
  local s = W.defaults()
  W.addWpt(s, { name = "Home", x = 10, y = -47, z = 20, type = "base" })
  t.truthy(W.save(path, s))
  local loaded, existed = W.load(path)
  t.eq(existed, true)
  t.eq(#loaded.waypoints, 1); t.eq(loaded.waypoints[1].name, "Home"); t.eq(loaded.waypoints[1].y, -47)
  fs.delete(path)
end)

t.test("load of a missing file is absent, not an error", function()
  local s, existed = W.load("/nope_nav_wpt.tbl")
  t.eq(s, nil); t.eq(existed, false)
end)

return true
