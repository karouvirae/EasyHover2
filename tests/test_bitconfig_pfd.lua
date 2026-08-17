-- tests/test_bitconfig_pfd.lua
-- PFD RATE sub-menu (ui/basalt/bitconfig/pfd.lua, screen id "pfdrate"): pure step/clamp seam +
-- persist seam, plus a real-CraftOS-PC Basalt construction probe. NEVER basalt.run().
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.pfd")
local BasaltApp = require("ui.basalt.app")
local Nav = require("ui.basalt.nav")

t.test("id is pfdrate -- distinct from the cockpit 'pfd' page in M.PAGES", function()
  t.eq(M.id, "pfdrate")
  t.eq(type(M.build), "function")
end)

t.test("step raises/lowers renderMs by STEP, clamped to [MIN,MAX]", function()
  local cfg = { pfd = { renderMs = 100 } }
  t.eq(M.step(cfg, 1), 100 + M.STEP)
  t.eq(cfg.pfd.renderMs, 100 + M.STEP)
  t.eq(M.step(cfg, -1), 100)
  cfg.pfd.renderMs = M.MAX
  t.eq(M.step(cfg, 1), M.MAX, "cannot exceed MAX")
  cfg.pfd.renderMs = M.MIN
  t.eq(M.step(cfg, -1), M.MIN, "cannot drop below MIN")
end)

t.test("step seeds pfd.renderMs when the config lacks it", function()
  local cfg = {}
  local v = M.step(cfg, 1)
  t.eq(type(v), "number")
  t.eq(type(cfg.pfd.renderMs), "number")
end)

t.test("_applyStep steps AND persists via the injected save", function()
  local saved = {}
  local runtime = { config = { pfd = { renderMs = 100 } } }
  M._applyStep(runtime, 1, { save = function(path, cfg) saved.path = path; saved.cfg = cfg end })
  t.eq(runtime.config.pfd.renderMs, 100 + M.STEP)
  t.eq(saved.cfg.pfd.renderMs, 100 + M.STEP, "persisted the updated config")
  t.truthy(saved.path ~= nil, "wrote to the UI config path")
end)

t.test("build constructs; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local runtime = { config = { pfd = { renderMs = 100 } }, uiRev = 0 }
  local h = M.build(basalt, frame, runtime, Nav.new("pfdrate"), { save = function() end })
  t.eq(h.id, "pfdrate")
  t.truthy(pcall(h.apply, {}), "apply must not error")
  t.truthy(pcall(function() basalt.update("timer", -1) end), "render pass must not error")
end)

return true
