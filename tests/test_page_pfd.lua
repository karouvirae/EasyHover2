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

  -- apply(nil) is safe (idempotent, nil-safe)
  local ok0 = pcall(function() page.apply(nil) end)
  t.truthy(ok0, "apply(nil) does not error")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

return true
