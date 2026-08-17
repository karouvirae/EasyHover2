-- tests/test_bitconfig_pfd.lua
-- PFD RATE sub-menu (ui/basalt/bitconfig/pfd.lua, screen id "pfdrate"): Hz-based rate control --
-- FASTER raises Hz (lowers renderMs), SLOWER lowers Hz -- plus the persist seam and a real-Basalt
-- construction probe. The render loop reads pfd.renderMs; this menu edits it in Hz terms.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.pfd")
local BasaltApp = require("ui.basalt.app")
local Nav = require("ui.basalt.nav")

t.test("id is pfdrate -- distinct from the cockpit 'pfd' page in M.PAGES", function()
  t.eq(M.id, "pfdrate")
  t.eq(type(M.build), "function")
end)

t.test("hz reports the current render rate in Hz from renderMs", function()
  t.eq(M.hz({ pfd = { renderMs = 100 } }), 10)
  t.eq(M.hz({ pfd = { renderMs = 50 } }), 20)
  t.eq(M.hz({}), M.hz({ pfd = { renderMs = M.DEFAULT_MS } }), "no pfd -> default")
end)

t.test("FASTER (delta +1) raises Hz and LOWERS renderMs; SLOWER does the opposite", function()
  local cfg = { pfd = { renderMs = 100 } }   -- 10 Hz
  M.step(cfg, 1)   -- faster -> 11 Hz
  t.eq(M.hz(cfg), 11, "faster -> higher Hz")
  t.truthy(cfg.pfd.renderMs < 100, "faster -> fewer ms (" .. cfg.pfd.renderMs .. ")")
  M.step(cfg, -1)  -- back to 10 Hz
  t.eq(M.hz(cfg), 10)
  t.truthy(cfg.pfd.renderMs >= 100, "slower -> more ms again")
end)

t.test("Hz clamps to [HZ_MIN, HZ_MAX]", function()
  local hi = { pfd = { renderMs = M.msOf(M.HZ_MAX) } }
  M.step(hi, 1); t.eq(M.hz(hi), M.HZ_MAX, "cannot exceed HZ_MAX")
  local lo = { pfd = { renderMs = M.msOf(M.HZ_MIN) } }
  M.step(lo, -1); t.eq(M.hz(lo), M.HZ_MIN, "cannot drop below HZ_MIN")
end)

t.test("step seeds pfd.renderMs when the config lacks it", function()
  local cfg = {}
  M.step(cfg, 1)
  t.eq(type(cfg.pfd.renderMs), "number")
end)

t.test("_applyStep steps AND persists via the injected save", function()
  local saved = {}
  local runtime = { config = { pfd = { renderMs = 100 } } }
  M._applyStep(runtime, 1, { save = function(path, cfg) saved.path = path; saved.cfg = cfg end })
  t.eq(M.hz(runtime.config), 11, "persisted config is faster")
  t.truthy(saved.cfg ~= nil and saved.cfg.pfd.renderMs < 100, "persisted the faster renderMs")
end)

t.test("build constructs; the value label shows Hz; apply + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local runtime = { config = { pfd = { renderMs = 100 } }, uiRev = 0 }
  local h = M.build(basalt, frame, runtime, Nav.new("pfdrate"), { save = function() end })
  t.eq(h.id, "pfdrate")
  t.truthy(h.elements.valueLabel:getText():find("Hz", 1, true), "value label shows Hz")
  t.truthy(pcall(h.apply, {}), "apply must not error")
  t.truthy(pcall(function() basalt.update("timer", -1) end), "render pass must not error")
end)

return true
