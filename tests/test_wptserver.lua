-- tests/test_wptserver.lua
-- Pure NAV-side sync server seam (nav/wptserver.lua): apply(store, msg, rev) -> reply, newStore,
-- newRev. Handles wpt_get + wpt_op (waypoint CRUD via nav.waypoints). No modem/peripherals -- the
-- transport (channels 108/109) is wired in nav/app.lua; this is just the request->effect mapping.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local S = require("nav.wptserver")
local W = require("nav.waypoints")

local function seed()
  local s = W.defaults()
  W.addWpt(s, { name = "Home", x = 10, y = -47, z = 20, type = "base" })
  return s
end

t.test("wpt_get returns the full store + rev, unchanged", function()
  local s = seed()
  local reply, newStore, newRev = S.apply(s, { k = "wpt_get" }, 3)
  t.eq(reply.k, "wpt_store")
  t.eq(#reply.store.waypoints, 1); t.eq(reply.rev, 3)
  t.eq(newRev, 3, "a read never bumps rev")
  t.eq(newStore, s)
end)

t.test("wpt_op addWpt applies, bumps rev, replies the new store", function()
  local s = seed()
  local reply, newStore, newRev = S.apply(s,
    { k = "wpt_op", op = "addWpt", args = { name = "Depot", x = 1, y = 2, z = 3, type = "outpost" } }, 5)
  t.eq(reply.k, "wpt_store")
  t.eq(#newStore.waypoints, 2, "waypoint added to the store")
  t.eq(newRev, 6, "a successful mutation bumps rev")
  t.eq(reply.rev, 6)
  t.truthy(W.find(newStore, "Depot") ~= nil)
end)

t.test("wpt_op editWpt / deleteWpt dispatch to the store", function()
  local s = seed()
  local _, s2, r2 = S.apply(s, { k = "wpt_op", op = "editWpt", args = { name = "Home", fields = { y = 99 } } }, 0)
  t.eq(W.find(s2, "Home").y, 99); t.eq(r2, 1)
  local _, s3, r3 = S.apply(s2, { k = "wpt_op", op = "deleteWpt", args = { name = "Home" } }, r2)
  t.eq(#s3.waypoints, 0); t.eq(r3, 2)
end)

t.test("a failed op does NOT bump rev and reports the error", function()
  local s = seed()
  local reply, newStore, newRev = S.apply(s,
    { k = "wpt_op", op = "addWpt", args = { name = "Home", x = 1, y = 1, z = 1, type = "poi" } }, 4)
  t.eq(#newStore.waypoints, 1, "duplicate name not added")
  t.eq(newRev, 4, "failed op keeps rev")
  t.truthy(reply.err ~= nil, "error surfaced to the client")
end)

t.test("route ops dispatch through apply (addRoute + addLeg) and bump rev", function()
  local s = seed()   -- has waypoint "Home"
  local _, s1, r1 = S.apply(s, { k = "wpt_op", op = "addRoute", args = { name = "Patrol" } }, 0)
  t.eq(#s1.routes, 1); t.eq(r1, 1)
  local _, s2, r2 = S.apply(s1, { k = "wpt_op", op = "addLeg", args = { route = "Patrol", wpt = "Home", alt = 90 } }, r1)
  t.eq(#W.findRoute(s2, "Patrol").legs, 1); t.eq(W.findRoute(s2, "Patrol").legs[1].alt, 90); t.eq(r2, 2)
  -- a bad leg (missing waypoint) fails without bumping rev
  local rep, _, r3 = S.apply(s2, { k = "wpt_op", op = "addLeg", args = { route = "Patrol", wpt = "ghost" } }, r2)
  t.eq(r3, r2); t.truthy(rep.err ~= nil)
end)

t.test("an unknown op / frame kind replies an error, store + rev untouched", function()
  local s = seed()
  local reply, newStore, newRev = S.apply(s, { k = "wpt_op", op = "nuke", args = {} }, 7)
  t.truthy(reply.err ~= nil); t.eq(newRev, 7); t.eq(newStore, s)
  local r2 = select(1, S.apply(s, { k = "bogus" }, 7))
  t.truthy(r2.err ~= nil)
end)

return true
