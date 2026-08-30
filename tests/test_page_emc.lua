-- tests/test_page_emc.lua
-- EMC standalone page (ui/basalt/pages/emc.lua): now a single graphical EMC region hosted full-frame
-- with a full border. Real-CraftOS-PC Basalt construction probe (never basalt.run()).
local t = require("tests.framework")
local M = require("ui.basalt.pages.emc")
local BasaltApp = require("ui.basalt.app")
local Nav = require("ui.basalt.nav")

t.test("id/title", function() t.eq(M.id, "emc"); t.eq(M.title, "EMC") end)

t.test("M.build hosts the EMC region; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("emc")
  local runtime = {
    config = { relay = { name = "relay0", side = "top" }, fuel = { pump = { full = 64 }, tank = { full = 8000 } } },
    engine = { status = function() return { master = false, feeding = false, pulses = 0 } end },
    uiRev = 0,
  }
  local h = M.build(basalt, frame, runtime, nav)
  t.eq(h.id, "emc")
  t.truthy(type(h.apply) == "function", "apply is a function")
  t.truthy(h.elements ~= nil and h.elements.region ~= nil, "hosts a region")
  local ok, err = pcall(h.apply, { pumpAmount = 32, tankMb = 4000, engineMaster = false, feeding = false })
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok2, "one render pass should not error")
end)
