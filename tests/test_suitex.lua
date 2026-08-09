package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
_G.EH2_SUITEX_NO_RUN = true
local SuiteX = require("easyhover2_suitex")

t.test("suitex loads as a library without running the UI", function()
  t.eq(type(SuiteX), "table")
end)

t.test("theme has matching high-contrast light/dark palettes", function()
  local d, l = SuiteX.theme.palettes.dark, SuiteX.theme.palettes.light
  for _, key in ipairs({ "bg","panel","text","dim","border","accent","ok","update","repair","error","install","btn","btnText","btnActive","btnDisabled" }) do
    t.truthy(d[key] ~= nil, "dark has " .. key); t.truthy(l[key] ~= nil, "light has " .. key)
  end
  t.truthy(d.bg ~= d.text, "dark bg != text"); t.truthy(l.bg ~= l.text, "light bg != text")
  t.eq(SuiteX.theme.get("nope"), SuiteX.theme.palettes.dark, "unknown mode -> dark")
end)

t.test("roleColour maps plan to a palette colour", function()
  local d = SuiteX.theme.palettes.dark
  t.eq(SuiteX.theme.roleColour(d, "current"), d.ok)
  t.eq(SuiteX.theme.roleColour(d, "update"), d.update)
  t.eq(SuiteX.theme.roleColour(d, "repair"), d.repair)
  t.eq(SuiteX.theme.roleColour(d, "install"), d.install)
end)

t.test("buttonStates: Go disabled only when already current", function()
  t.eq(SuiteX.buttonStates("update").go, "active")
  t.eq(SuiteX.buttonStates("current").go, "disabled")
  t.eq(SuiteX.buttonStates("current").verify, "active")
end)

t.test("planView builds status lines with the plan-aware diff label", function()
  local v = SuiteX.planView({ role="fcs", state={version="a"}, manifest={version="b"}, plan="update",
    report={ missing={}, corrupt={"x","y"}, total=10, present=10 }, diffLabel="outdated" })
  local byLabel = {}; for _,l in ipairs(v.lines) do byLabel[l.label]=l end
  t.eq(byLabel.installed.value, "a"); t.eq(byLabel.release.value, "b")
  t.eq(byLabel.plan.role, "update")
  t.eq(byLabel.files.value, "8 ok / 0 missing / 2 outdated")
  t.eq(v.buttons.go, "active")
end)

t.test("checkDriver steps to completion and reports like a one-shot check", function()
  local files = { {dst="a"},{dst="b"},{dst="c"},{dst="d"} }
  local verdict = { a="ok", b="corrupt", c="ok", d="missing" }
  local drv = SuiteX.checkDriver(files, function(e) return verdict[e.dst] end)
  local done = drv.step(2); t.eq(done, false)
  local i, total = drv.progress(); t.eq(i, 2); t.eq(total, 4)
  done = drv.step(10); t.eq(done, true)               -- clamps past the end
  local r = drv.result()
  t.eq(#r.corrupt, 1); t.eq(#r.missing, 1); t.eq(r.present, 3); t.eq(r.total, 4); t.eq(r.ok, false)
end)

t.test("logo is a rectangular ASCII block", function()
  t.truthy(#SuiteX.logo >= 1, "has rows")
  local w = #SuiteX.logo[1]
  for _, row in ipairs(SuiteX.logo) do t.eq(#row, w, "rows equal width") end
  local lw, lh = SuiteX.logoSize(); t.eq(lw, w); t.eq(lh, #SuiteX.logo)
  t.truthy(w <= 49, "fits a 51-wide terminal with margin")
end)
