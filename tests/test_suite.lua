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
