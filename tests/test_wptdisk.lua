-- tests/test_wptdisk.lua
-- Pure NAV-side waypoint/route disk courier (nav/wptdisk.lua): export the store to a disk, import
-- (MERGE, dedupe by name) from a disk, and scan a disk for a valid nav file. deps (read/write/delete)
-- injected so no real disk drive is touched. Mirrors ui/basalt/bitconfig/dtc.lua's seams.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local D = require("nav.wptdisk")
local W = require("nav.waypoints")

-- a fake disk filesystem keyed by path
local function fakeDeps(files)
  files = files or {}
  return files, {
    read  = function(p) return files[p] end,
    write = function(p, body) files[p] = body; return true end,
    delete = function(p) files[p] = nil end,
  }
end

t.test("diskPath is <mount>/eh2_nav_wpt.tbl", function()
  t.eq(D.diskPath("disk"), "/disk/eh2_nav_wpt.tbl")
end)

t.test("export writes the serialised store to the disk", function()
  local files, deps = fakeDeps()
  local s = W.defaults(); W.addWpt(s, { name = "Home", x = 1, y = 2, z = 3, type = "base" })
  t.eq(D.export(s, "disk", deps), true)
  t.truthy(files["/disk/eh2_nav_wpt.tbl"] ~= nil, "file written")
  t.truthy(files["/disk/eh2_nav_wpt.tbl"]:find("Home", 1, true))
end)

t.test("scan reports a valid nav file / foreign / absent", function()
  local diskStore = W.defaults(); W.addWpt(diskStore, { name = "A", x = 1, y = 1, z = 1, type = "poi" })
  local _, deps = fakeDeps({ ["/disk/eh2_nav_wpt.tbl"] = textutils.serialise(diskStore) })
  local r = D.scan("disk", deps)
  t.eq(r.hasDisk, true); t.eq(r.valid, true)
  local _, d2 = fakeDeps({ ["/disk/eh2_nav_wpt.tbl"] = "garbage not a table" })
  t.eq(D.scan("disk", d2).valid, false, "foreign/corrupt file -> not valid")
  local _, d3 = fakeDeps({})
  t.eq(D.scan("disk", d3).hasDisk, false, "no file -> absent")
end)

t.test("import MERGES the disk store into the local one (dedupe by name)", function()
  local diskStore = W.defaults()
  W.addWpt(diskStore, { name = "A", x = 9, y = 9, z = 9, type = "poi" })     -- replaces local A
  W.addWpt(diskStore, { name = "B", x = 2, y = 2, z = 2, type = "outpost" }) -- new
  local _, deps = fakeDeps({ ["/disk/eh2_nav_wpt.tbl"] = textutils.serialise(diskStore) })

  local local_ = W.defaults()
  W.addWpt(local_, { name = "A", x = 1, y = 1, z = 1, type = "base" })
  local merged = D.import(local_, "disk", deps)
  t.truthy(merged ~= nil)
  t.eq(#merged.waypoints, 2)
  t.eq(W.find(merged, "A").x, 9); t.eq(W.find(merged, "A").type, "poi")   -- replaced
  t.truthy(W.find(merged, "B") ~= nil)
end)

t.test("import rejects a foreign/absent disk file", function()
  local _, d1 = fakeDeps({ ["/disk/eh2_nav_wpt.tbl"] = "not a store" })
  t.eq(D.import(W.defaults(), "disk", d1), nil, "foreign -> nil")
  local _, d2 = fakeDeps({})
  t.eq(D.import(W.defaults(), "disk", d2), nil, "absent -> nil")
end)

t.test("nil mount -> no-op errors, never crash", function()
  local _, deps = fakeDeps()
  t.eq(D.export(W.defaults(), nil, deps), false)
  t.eq(D.import(W.defaults(), nil, deps), nil)
  t.eq(D.scan(nil, deps).hasDisk, false)
end)

return true
