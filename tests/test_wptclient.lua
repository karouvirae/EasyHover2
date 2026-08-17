-- tests/test_wptclient.lua
-- Cockpit-side NAV store sync client (ui/basalt/wptclient.lua): PURE request-frame builders + the
-- reply->cache seam. The modem round-trip (send on 108, await on 109 w/ timeout+retry) is in-game
-- glue in nav/app.lua's peer; here we test the framing + cache logic headless.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Client = require("ui.basalt.wptclient")

t.test("request-frame builders have the wire shapes wptserver expects", function()
  t.eq(Client.getFrame().k, "wpt_get")
  local op = Client.opFrame("addWpt", { name = "A" }, 7)
  t.eq(op.k, "wpt_op"); t.eq(op.op, "addWpt"); t.eq(op.args.name, "A"); t.eq(op.rev, 7)
  local dk = Client.diskFrame("export")
  t.eq(dk.k, "wpt_disk"); t.eq(dk.op, "export")
end)

t.test("a fresh client starts offline with an empty store", function()
  local c = Client.new({})
  t.eq(c.online, false)
  t.eq(#c.store.waypoints, 0); t.eq(#c.store.routes, 0)
  t.eq(c.rev, -1)
end)

t.test("onReply(wpt_store) refreshes the cache + marks online", function()
  local c = Client.new({})
  local changed = c:onReply({ k = "wpt_store",
    store = { waypoints = { { name = "Home", x = 1, y = 2, z = 3, type = "base" } }, routes = {} },
    rev = 4 })
  t.eq(changed, true)
  t.eq(c.online, true); t.eq(c.rev, 4)
  t.eq(#c.store.waypoints, 1); t.eq(c.store.waypoints[1].name, "Home")
end)

t.test("onReply(wpt_store) with an err carries it but still updates the store", function()
  local c = Client.new({})
  c:onReply({ k = "wpt_store", store = { waypoints = {}, routes = {} }, rev = 2, err = "name exists" })
  t.eq(c.lastErr, "name exists"); t.eq(c.online, true)
end)

t.test("onReply(wpt_disk_res) records the disk result + marks online, not a store update", function()
  local c = Client.new({})
  local changed = c:onReply({ k = "wpt_disk_res", op = "scan", result = { hasDisk = true, valid = true } }, 10)
  t.eq(changed, false); t.eq(c.online, true)
  t.truthy(c.lastDisk ~= nil and c.lastDisk.op == "scan")
end)

t.test("onReply(wpt_err) records the error, is not a store update", function()
  local c = Client.new({})
  local changed = c:onReply({ k = "wpt_err", err = "bad" })
  t.eq(changed, false); t.eq(c.lastErr, "bad")
end)

t.test("onReply ignores garbage without crashing", function()
  local c = Client.new({})
  t.eq(c:onReply(nil), false)
  t.eq(c:onReply({ k = "nope" }), false)
  t.eq(c:onReply("string"), false)
  t.eq(#c.store.waypoints, 0)
end)

return true
