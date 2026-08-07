-- EasyHover 2 Suite unit tests. Run under tests/run_headless.sh.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")   -- existing project test framework

local fnv1a = require("tools.fnv1a")

t.test("fnv1a reference vectors", function()
  t.eq(fnv1a(""), "811c9dc5")
  t.eq(fnv1a("a"), "e40c292c")
  t.eq(fnv1a("hello"), "4f9f2cab")
end)

local Config = require("fcs.io.config")

t.test("config withDefaults is additive over hwconfig", function()
  local merged = Config.withDefaults({ bindings = { signPitch = -1 } })
  t.eq(merged.bindings.signPitch, -1)      -- kept
  t.eq(merged.bindings.signRoll, 1)        -- filled from defaults
  t.eq(merged.fuelRelay, false)            -- filled from defaults
end)

t.test("config save then load round-trips", function()
  local path = "/eh2_test_cfg.tbl"
  if fs.exists(path) then fs.delete(path) end
  local ok = Config.save(path, { bindings = { yawBaseline = 3 } })
  t.eq(ok, true)
  local cfg, existed, err = Config.load(path)
  t.eq(existed, true); t.eq(err, nil); t.eq(cfg.bindings.yawBaseline, 3)
  fs.delete(path)
end)

t.test("config load reports absent + unparseable distinctly", function()
  local cfg, existed = Config.load("/eh2_nope.tbl")
  t.eq(existed, false)
  local bad = "/eh2_bad_cfg.tbl"
  local f = fs.open(bad, "w"); f.write("this is not = a table {{{"); f.close()
  local c2, ex2, err2 = Config.load(bad)
  t.eq(ex2, true)          -- the file exists
  t.eq(err2 ~= nil, true)  -- but did not parse
  fs.delete(bad)
end)

local closure = require("tools.closure")

t.test("closure follows literal require() and dedupes", function()
  local files = {
    ["a.lua"]     = 'local b = require("b")\nlocal c = require("pkg.c")',
    ["b.lua"]     = 'local c = require("pkg.c")',
    ["pkg/c.lua"] = '-- leaf, no requires',
  }
  local read = function(p) return files[p] end
  local out, err = closure.resolve({ "a.lua" }, read)
  t.eq(err, nil)
  t.eq(table.concat(out, ","), "a.lua,b.lua,pkg/c.lua")
end)

t.test("closure resolves init.lua form and unions multiple roots", function()
  local files = {
    ["app.lua"]      = 'require("mod")',
    ["mod/init.lua"] = '-- package',
    ["tool.lua"]     = 'require("mod")',
  }
  local out = closure.resolve({ "tool.lua", "app.lua" }, function(p) return files[p] end)
  t.eq(table.concat(out, ","), "app.lua,mod/init.lua,tool.lua")
end)

t.test("closure errors on unresolvable require", function()
  local read = function(p) if p == "a.lua" then return 'require("ghost")' end end
  local out, err = closure.resolve({ "a.lua" }, read)
  t.eq(out, nil)
  t.eq(err:find("ghost") ~= nil, true)
end)

-- tools/gen_manifest.lua exposes its pure helpers (deterministic serialiser, dirs derivation)
-- on a table when _G.EH2_GEN_TEST is set, so they can be unit-tested without touching fs.
_G.EH2_GEN_TEST = true
local gen = require("tools.gen_manifest")
_G.EH2_GEN_TEST = nil

t.test("gen_manifest luaValue serialises map keys in sorted order", function()
  t.eq(gen.luaValue({ b = 2, a = 1 }, 0), "{\n  [\"a\"] = 1,\n  [\"b\"] = 2,\n}")
end)

t.test("gen_manifest luaValue keeps array order and quotes/escapes strings", function()
  t.eq(gen.luaValue({ "x", "y" }, 0), "{\n  \"x\",\n  \"y\",\n}")
  t.eq(gen.luaValue('a"b\\c', 0), '"a\\"b\\\\c"')
  t.eq(gen.luaValue({}, 0), "{}")
end)

t.test("gen_manifest dirsOf derives the top-level directory repair scope", function()
  local dirs = gen.dirsOf({ "fcs/x.lua", "tools/y.lua", "startup.lua" })
  t.eq(table.concat(dirs, ","), "fcs,tools")
end)

_G.EH2_SUITE_NO_RUN = true
local Suite = require("easyhover2_suite")

t.test("suite checksum matches shared fnv1a", function()
  t.eq(Suite.checksum("hello"), fnv1a("hello"))
  t.eq(Suite.checksum(""), "811c9dc5")
end)

t.test("isProtected covers EH2 config + suite files", function()
  t.eq(Suite.isProtected("/eh2_hw_config.tbl"), true)
  t.eq(Suite.isProtected("/easyhover2_install.txt"), true)
  t.eq(Suite.isProtected("/easyhover2_backup/x"), true)
  t.eq(Suite.isProtected("/fcs/io/config.lua"), false)  -- code is not protected
end)

t.test("choosePlan truth table (carried from v1)", function()
  t.eq(Suite.choosePlan({ anyInstall = false }), "install")
  t.eq(Suite.choosePlan({ anyInstall = true, forceRepair = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, noRecord = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = true, mismatched = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = true, mismatched = false }), "current")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = false }), "update")
end)

local function fakeManifest()
  return { roles = {
    fcs = { status="released", files = {
      { dst="startup.lua", size=3, sum=Suite.checksum("fcs") },
      { dst="tools/flight.lua", size=1, sum="x" },
      { dst="fcs/io/backend.lua", size=1, sum="y" },
    }},
    ui = { status="released", files = {
      { dst="startup.lua", size=2, sum=Suite.checksum("ui") },
      { dst="ui/main.lua", size=1, sum="z" },
      { dst="fcs/io/backend.lua", size=1, sum="y" },
    }},
  }}
end

t.test("detectRole keys on the installed startup launcher", function()
  local m = fakeManifest()
  local disk = { ["/startup.lua"] = "ui" }  -- matches ui's startup sum
  local exists = function(p) return disk[p] ~= nil end
  local read = function(p) return disk[p] end
  local role = Suite.detectRole(m, exists, read)
  t.eq(role, "ui")
end)

t.test("detectRole falls back to unique files when startup is missing", function()
  local m = fakeManifest()
  local disk = { ["/tools/flight.lua"] = "a", ["/fcs/io/backend.lua"] = "b" }  -- fcs-unique present
  local exists = function(p) return disk[p] ~= nil end
  local read = function(p) return disk[p] end
  local role = Suite.detectRole(m, exists, read)
  t.eq(role, "fcs")
end)

t.test("backup keeps exactly one (latest) copy", function()
  local root = "/easyhover2_backup"
  if fs.exists(root) then fs.delete(root) end
  local src = "/eh2_hw_config.tbl"
  local f = fs.open(src, "w"); f.write("v1"); f.close()
  Suite.backupConfig(src, "verA")     -- new API: single-latest
  f = fs.open(src, "w"); f.write("v2"); f.close()
  Suite.backupConfig(src, "verB")
  -- exactly one backup file remains, containing the latest pre-backup content ("v2")
  local names = fs.list(root)
  t.eq(#names, 1)
  local bf = fs.open(root .. "/" .. names[1], "r"); local body = bf.readAll(); bf.close()
  t.eq(body, "v2")
  fs.delete(src); fs.delete(root)
end)

t.test("extendConfig uses the manifest's configModule (additive)", function()
  local path = "/eh2_hw_config.tbl"
  local Config = require("fcs.io.config")
  Config.save(path, { bindings = { signPitch = -1 } })   -- a pilot value, missing new keys
  local spec = { configModule = "fcs.io.config", luaPath = "/" }
  local result = Suite.extendConfig(spec, path, "verX")
  t.eq(result, "extended")
  local cfg = Config.load(path)
  t.eq(cfg.bindings.signPitch, -1)      -- kept
  t.eq(cfg.bindings.signRoll, 1)        -- filled from defaults
  fs.delete(path)
end)
