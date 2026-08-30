-- tests/test_page_fcs.lua
-- FCS standalone page (ui/basalt/pages/fcs.lua): now the FLIGHT-graphical FCS region hosted full-frame.
local t = require("tests.framework")
local M = require("ui.basalt.pages.fcs")
local BasaltApp = require("ui.basalt.app")
local Nav = require("ui.basalt.nav")

t.test("id/title", function() t.eq(M.id, "fcs"); t.eq(M.title, "FCS") end)

t.test("M.build hosts the FCS region; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("fcs")
  local runtime = {
    rx = { latest = function() return {} end },
    links = { tel = { send = function() end } },
    sender = { send = function(_, c) return c end },
    uiRev = 0,
  }
  local h = M.build(basalt, frame, runtime, nav)
  t.eq(h.id, "fcs")
  t.truthy(h.elements ~= nil and h.elements.region ~= nil, "hosts a region")
  local ok, err = pcall(h.apply, { engaged = false, gndSafety = false, flightMode = "PRECISION", masterMode = "CPL" })
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok2, "one render pass should not error")
end)
