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

-- in-memory deps store (mirrors test_splitconfig / test_bitconfig_dtc conventions)
local function fakeDeps(localFiles, mount)
  local files = {}
  for k, v in pairs(localFiles or {}) do files[k] = v end
  local drive = mount and {
    isDiskPresent = function() return true end,
    getMountPath  = function() return mount end,
  } or nil
  local deps = {
    find   = function(kind) return (kind == "drive") and drive or nil end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    write  = function(p, body) files[p] = body end,
  }
  return files, deps
end

t.test("run: dumps every present local kind to <mount>/<cfgspec.FILES[kind]>", function()
  local files, deps = fakeDeps({
    ["/eh2_devbind.tbl"] = "DB", ["/eh2_tuning.tbl"] = "TN",
  }, "disk")
  local summary = F.run(deps)
  t.eq(files["/disk/eh2_devbind.tbl"], "DB")
  t.eq(files["/disk/eh2_tuning.tbl"], "TN")
  t.eq(files["/disk/eh2_senscal.tbl"], nil, "senscal absent locally -> not written")
  t.truthy(summary:find("devbind", 1, true) and summary:find("senscal", 1, true),
    "summary names dumped + missing kinds: " .. summary)
end)

t.test("run: no drive found -> writes nothing, reports no-mount", function()
  local files, deps = fakeDeps({ ["/eh2_devbind.tbl"] = "DB" }, nil)
  local summary = F.run(deps)
  t.eq(files["/disk/eh2_devbind.tbl"], nil)
  t.truthy(summary:lower():find("disk", 1, true), "summary mentions the missing disk: " .. summary)
end)
