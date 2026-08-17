-- tests/test_page_pfd.lua
-- PFD cockpit page (ui/basalt/pages/pfd.lua): pure exports + registration, plus a real-CraftOS-PC
-- Basalt construction probe (build on a frame bound to term.current(), apply() a mock instrument
-- state, one basalt.update render pass). NEVER basalt.run() (blocks on pullEventRaw).
local t = require("tests.framework")
local PFD = require("ui.basalt.pages.pfd")
local BasaltApp = require("ui.basalt.app")
local Config = require("ui.basalt.pages.config")

t.test("pfd exports id/title and a build fn", function()
  t.eq(PFD.id, "pfd"); t.eq(PFD.title, "PFD")
  t.eq(type(PFD.build), "function")
end)

t.test("pfd is a registered, monitor-assignable page", function()
  t.truthy(BasaltApp.PAGES.pfd, "pfd in M.PAGES")
  local found = false
  for _, id in ipairs(Config.ASSIGN_CYCLE) do if id == "pfd" then found = true end end
  t.truthy(found, "pfd in ASSIGN_CYCLE")
end)

t.test("build + apply render without error and reflect state text", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local page = PFD.build(basalt, frame, {}, nil)

  t.eq(page.id, "pfd")
  t.truthy(type(page.apply) == "function", "apply is a function")
  t.truthy(page.elements and page.elements.lubberLabel, "elements exposed")

  page.apply({ heading = 90, pitch = 0, roll = 0, baroAlt = 87.4, sas = 12.2 })

  -- lubber shows the heading; readouts show baro+sas by default
  t.eq(page.elements.lubberLabel:getText(), "090", "lubber shows 3-digit heading")
  t.eq(page.elements.altLabel:getText(), "ALT 87Baro", "ALT default baro")
  t.eq(page.elements.spdLabel:getText(), "SPD 12SAS", "SPD default sas")

  -- a repaint with new heading updates the tape lubber label
  page.apply({ heading = 0 })
  t.eq(page.elements.lubberLabel:getText(), "000", "lubber updates on repaint")

  -- no fresh nav bearing (heading nil) -> tape shows "---", NOT a fabricated 000/N
  page.apply({ heading = nil, pitch = 0, roll = 0 })
  t.eq(page.elements.lubberLabel:getText(), "---", "unknown heading shows dashes")
  t.eq(page.elements.tapeLabel:getText(), string.rep(" ", ({frame:getSize()})[1]), "tape blank when heading unknown")

  -- SEAM: the LIVE cockpit cadence state names baro altitude `altitude` (ui/basalt/app.lua
  -- M.buildState), not `baroAlt`. The page must bridge it so baro-ALT reads live in-game.
  page.apply({ heading = 0, altitude = 87.4 })
  t.eq(page.elements.altLabel:getText(), "ALT 87Baro", "live `altitude` field drives baro-ALT")
  -- an explicit contract `baroAlt` still wins if a future Batch-B feed sets it
  page.apply({ heading = 0, altitude = 87.4, baroAlt = 42.0 })
  t.eq(page.elements.altLabel:getText(), "ALT 42Baro", "explicit baroAlt takes precedence")

  -- waypoint target cue: bearing bug on the tape + TGT readout appear when a target is present
  page.apply({ heading = 0, target = { name = "Home", bearing = 6, distanceH = 340, relBearing = 6,
    altDelta = 12, color = "green" } })
  t.eq(page.elements.bugLabel:getText(), "v", "bearing bug shown for an on-tape target")
  t.truthy(page.elements.tgtLine1:getText():find("Home", 1, true), "TGT name shown")
  t.truthy(page.elements.tgtLine2:getText():find("340m", 1, true), "TGT distance shown")
  -- target OFF the visible tape (bearing far from heading) -> an edge arrow shows which way to turn
  page.apply({ heading = 0, target = { name = "Far", bearing = 90, distanceH = 2000, relBearing = 90,
    altDelta = 0, color = "green" } })
  t.eq(page.elements.bugLabel:getText(), ">", "off-tape target to the right -> right edge arrow")
  page.apply({ heading = 0, target = { name = "Far", bearing = 270, distanceH = 2000, relBearing = -90,
    altDelta = 0, color = "green" } })
  t.eq(page.elements.bugLabel:getText(), "<", "off-tape target to the left -> left edge arrow")

  -- no target -> cue hidden
  page.apply({ heading = 0 })
  t.eq(page.elements.bugLabel:getText(), "", "bug hidden with no target")
  t.eq(page.elements.tgtLine1:getText(), "", "TGT readout cleared with no target")

  -- apply(nil) is safe (idempotent, nil-safe)
  local ok0 = pcall(function() page.apply(nil) end)
  t.truthy(ok0, "apply(nil) does not error")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("buildState surfaces the PFD sensor + gps fields from runtime.state/runtime.nav", function()
  local BasaltApp = require("ui.basalt.app")
  local runtime = {
    rx = { latest = function() return { heading = 12, altitude = 80 } end },
    engine = { status = function() return {} end },
    hbRx = { up = function() return true end },
    state = { pitch = 4, roll = -2, sas = 6, pumpFrac = 0, tankFrac = 0 },
    nav = { gpsAlt = 91, tas = 7, fixOk = true },
    uiRev = 1,
  }
  local s = BasaltApp.buildState(runtime, 1000)
  t.eq(s.pitch, 4); t.eq(s.roll, -2); t.eq(s.sas, 6)
  t.eq(s.gpsAlt, 91); t.eq(s.tas, 7); t.eq(s.gpsFixOk, true)
end)

t.test("buildState is nil-safe when runtime.state fields and runtime.nav are all nil", function()
  local BasaltApp = require("ui.basalt.app")
  local runtime = {
    rx = { latest = function() return {} end },
    engine = { status = function() return {} end },
    hbRx = { up = function() return true end },
    state = { pumpFrac = 0, tankFrac = 0 },
    nav = {},
    uiRev = 1,
  }
  local ok, s = pcall(BasaltApp.buildState, runtime, 1000)
  t.truthy(ok, "buildState should not error when pitch/roll/sas/gpsAlt/tas/gpsFixOk are all nil")
  t.eq(s.pitch, nil); t.eq(s.roll, nil); t.eq(s.sas, nil)
  t.eq(s.gpsAlt, nil); t.eq(s.tas, nil); t.eq(s.gpsFixOk, nil)
end)

return true
