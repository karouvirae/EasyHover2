package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Config = require("ui.config")

t.test("defaults has the full schema", function()
  local d = Config.defaults()
  t.eq(type(d.assign), "table")
  t.eq(d.engine.pulseMs, 250)
  t.eq(d.engine.intervalMs, 330000)   -- 5m30s: one blaze-cake burn on this server
  t.eq(d.engine.invert, false)
  t.eq(d.fuel.pump.kind, "inventory")
end)

t.test("withDefaults keeps saved values and fills new ones", function()
  local merged = Config.withDefaults({ engine = { pulseMs = 300 }, assign = { ["monitor_1"] = "engine" } })
  t.eq(merged.engine.pulseMs, 300)          -- kept
  t.eq(merged.engine.intervalMs, 330000)    -- filled from defaults (5m30s)
  t.eq(merged.assign["monitor_1"], "engine")-- kept
  t.eq(merged.relay.name, nil)              -- default
end)

t.test("save then load round-trips (pre-merge)", function()
  local path = "/eh2_ui_config.tbl"
  if fs.exists(path) then fs.delete(path) end
  local ok = Config.save(path, { assign = { ["m"] = "fcs" }, engine = { invert = true } })
  t.eq(ok, true)
  local cfg, existed, err = Config.load(path)
  t.eq(existed, true); t.eq(err, nil)
  t.eq(cfg.assign["m"], "fcs")
  t.eq(cfg.engine.invert, true)
  t.eq(cfg.engine.pulseMs, nil)             -- load is pre-merge
  fs.delete(path)
end)

t.test("load of a missing file is absent, not an error", function()
  local cfg, existed, err = Config.load("/nope_ui.tbl")
  t.eq(cfg, nil); t.eq(existed, false); t.eq(err, nil)
end)

t.test("load of unparseable is present-with-error", function()
  local path = "/eh2_ui_bad.tbl"
  local f = fs.open(path, "w"); f.write("not a table"); f.close()
  local cfg, existed, err = Config.load(path)
  t.eq(existed, true); t.eq(type(err), "string")
  fs.delete(path)
end)

t.test("pfd render rate defaults to 100ms and round-trips through withDefaults", function()
  t.eq(Config.defaults().pfd.renderMs, 100, "default PFD render cadence")
  t.eq(Config.withDefaults({ pfd = { renderMs = 200 } }).pfd.renderMs, 200, "saved value kept")
  t.eq(Config.withDefaults({}).pfd.renderMs, 100, "filled from defaults")
end)

t.test("sens concern defaults to FCS and preserves a saved source + self cal", function()
  t.eq(Config.withDefaults({}).sens.source, "FCS", "default source")
  local kept = Config.withDefaults({ sens = { source = "SELF", self = { signPitch = -1 } } })
  t.eq(kept.sens.source, "SELF"); t.eq(kept.sens.self.signPitch, -1)
end)
