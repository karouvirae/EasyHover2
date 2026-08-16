package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local C = require("beacon.config")

t.test("defaults carry a shared GPS channel, a 1 Hz interval, and broadcasting enabled", function()
  local d = C.defaults()
  t.eq(d.channel, 65000)
  t.eq(d.intervalMs, 1000)
  t.eq(d.enabled, true)
  t.truthy(type(d.pos) == "table", "has a position sub-table (coords unset until configured)")
end)

t.test("clampInterval enforces the 1 Hz floor (never faster than the FCS-safety rate)", function()
  t.eq(C.clampInterval(500), 1000)    -- too fast -> clamped up to the floor
  t.eq(C.clampInterval(1000), 1000)
  t.eq(C.clampInterval(5000), 5000)   -- slower is fine
  t.eq(C.clampInterval(nil), 1000)    -- default is the floor
end)

t.test("withDefaults deep-merges saved values over fresh defaults", function()
  local m = C.withDefaults({ id = "B1", channel = 65001, pos = { x = 1, y = 2, z = 3 } })
  t.eq(m.id, "B1")
  t.eq(m.channel, 65001)     -- saved wins
  t.eq(m.intervalMs, 1000)   -- untouched default survives
  t.eq(m.pos.x, 1); t.eq(m.pos.y, 2); t.eq(m.pos.z, 3)
end)

t.test("save then load round-trips the saved (pre-merge) table", function()
  local path = "/test_eh2_beacon.tbl"
  if fs.exists(path) then fs.delete(path) end
  local cfg = { id = "B3", channel = 65000, intervalMs = 2000, pos = { x = 10, y = 20, z = 30 } }
  t.truthy(C.save(path, cfg))
  local loaded, existed = C.load(path)
  t.eq(existed, true)
  t.eq(loaded.id, "B3")
  t.eq(loaded.intervalMs, 2000)
  t.eq(loaded.pos.z, 30)
  fs.delete(path)
end)

t.test("a saved updateToken is preserved through withDefaults; absent stays nil (fail-closed)", function()
  t.eq(C.withDefaults({ updateToken = "abc" }).updateToken, "abc", "saved token kept")
  t.eq(C.withDefaults({}).updateToken, nil, "absent -> nil (fail-closed)")
end)
