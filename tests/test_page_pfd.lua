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

t.test("build exposes the three canvases; apply renders states without error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local page = PFD.build(basalt, frame, {}, nil)

  t.eq(page.id, "pfd")
  t.truthy(type(page.apply) == "function", "apply is a function")
  t.truthy(page.elements and page.elements.tapeImg and page.elements.adiImg and page.elements.roImg,
    "tape / adi / readout canvases exposed")

  -- The numbers are drawn as subpixel glyphs onto Image canvases (no text Labels to read back), so we
  -- snapshot each canvas's cells and assert it CHANGES with the state it depends on.
  local function snap(img)
    local w, hh = img:getImageSize(); local s = {}
    for y = 1, hh do for x = 1, w do s[#s + 1] = tostring(img:getBg(x, y)) end end
    return table.concat(s)
  end

  page.apply({ heading = 90, pitch = 0, roll = 0, baroAlt = 87.4, sas = 12.2 })
  local ro1, tp1 = snap(page.elements.roImg), snap(page.elements.tapeImg)

  -- ALT/SPD readouts change when their values change
  page.apply({ heading = 90, pitch = 0, roll = 0, baroAlt = 222.2, sas = 99.9 })
  t.truthy(snap(page.elements.roImg) ~= ro1, "readout canvas changes when ALT/SPD change")

  -- tape changes when heading changes
  page.apply({ heading = 12, pitch = 0, roll = 0, baroAlt = 222.2, sas = 99.9 })
  t.truthy(snap(page.elements.tapeImg) ~= tp1, "tape canvas changes when heading changes")

  -- the live cadence state names baro altitude `altitude`; an explicit `baroAlt` still wins. Both
  -- must render without error (value correctness of the bridge is covered by the readout helper logic).
  local okBridge = pcall(function()
    page.apply({ heading = 0, altitude = 87.4 })
    page.apply({ heading = 0, altitude = 87.4, baroAlt = 42.0 })
  end)
  t.truthy(okBridge, "altitude/baroAlt bridge renders without error")

  -- a waypoint target (on-tape and off-tape) renders without error
  local okTgt = pcall(function()
    page.apply({ heading = 0, target = { name = "Home", bearing = 6, distanceH = 340, relBearing = 6, altDelta = 12, color = "green" } })
    page.apply({ heading = 0, target = { name = "Far", bearing = 90, distanceH = 2000, relBearing = 90, altDelta = 0, color = "green" } })
    page.apply({ heading = 0 })   -- no target
  end)
  t.truthy(okTgt, "target cue renders (on-tape, off-tape, none) without error")

  -- unknown heading (no fresh nav bearing) renders without error, and apply(nil) is nil-safe
  local okNil = pcall(function() page.apply({ heading = nil, pitch = 0, roll = 0 }); page.apply(nil) end)
  t.truthy(okNil, "nil heading and apply(nil) are safe")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("attitude indicator responds to a realistic RADIAN bank (rad->deg at the page seam)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local page = PFD.build(basalt, frame, {}, nil)

  -- Attitude is now a graphical ADI drawn onto an Image canvas (page.elements.adiImg), not text
  -- rows. Snapshot the canvas (bg blit per cell) and confirm a bank changes it.
  local adi = page.elements.adiImg
  local function snap()
    local w, hh = adi:getImageSize()
    local s = {}
    for y = 1, hh do for x = 1, w do s[#s + 1] = tostring(adi:getBg(x, y)) end end
    return table.concat(s)
  end

  page.apply({ heading = 0, pitch = 0, roll = 0 })
  local level = snap()

  -- 0.35 rad = ~20 degrees of right bank. The FCS reports pitch/roll in RADIANS; the ADI is
  -- degree-based, so the page must convert -- else 0.35 is drawn as 0.35 deg -> visually flat ->
  -- an identical canvas.
  page.apply({ heading = 0, pitch = 0, roll = 0.35 })
  t.truthy(snap() ~= level, "a 20-degree (0.35 rad) bank must visibly tilt the attitude indicator")
end)

t.test("buildState surfaces the PFD sensor + gps fields from the FCS snapshot (rx) and runtime.nav", function()
  local BasaltApp = require("ui.basalt.app")
  local runtime = {
    rx = { latest = function() return { heading = 12, altitude = 80, pitch = 4, roll = -2, surgeVel = 6 } end },
    engine = { status = function() return {} end },
    hbRx = { up = function() return true end },
    state = { pumpFrac = 0, tankFrac = 0 },
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
