-- tests/test_theme.lua -- the central colour system (ui/theme.lua): resolution, theme, palette.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Theme = require("ui.theme")

t.test("DEFAULTS: green font, dark-gray button, yellow wpt, blue rt, no colourblind", function()
  t.eq(Theme.DEFAULTS.font, "green")
  t.eq(Theme.DEFAULTS.button, "darkGray")
  t.eq(Theme.DEFAULTS.wpt, "yellow")
  t.eq(Theme.DEFAULTS.rt, "blue")
  t.eq(Theme.DEFAULTS.colorblind, "none")
end)

t.test("resolve: nil/missing config falls back to the role defaults", function()
  t.eq(Theme.resolve(nil, "font"), colors.green)
  t.eq(Theme.resolve({}, "button"), colors.gray)        -- "darkGray" -> CC gray (0x4c4c4c)
  t.eq(Theme.resolve(nil, "wpt"), colors.yellow)
  t.eq(Theme.resolve(nil, "rt"), colors.blue)
end)

t.test("resolve: explicit choices map to their CC slot", function()
  t.eq(Theme.resolve({ font = "lime" }, "font"), colors.lime)
  t.eq(Theme.resolve({ font = "white" }, "font"), colors.white)
  t.eq(Theme.resolve({ button = "gray" }, "button"), colors.lightGray)  -- gray -> CC lightGray (medium)
  t.eq(Theme.resolve({ font = "orange" }, "font"), colors.orange)       -- orange -> native slot
  t.eq(Theme.resolve({ wpt = "lightRed" }, "wpt"), colors.brown)        -- lightRed repurposes brown
end)

t.test("resolve: an unknown colour name falls back to the role default", function()
  t.eq(Theme.resolve({ font = "chartreuse" }, "font"), colors.green)
end)

t.test("COLOR_CHOICES has 15 entries (incl. orange); COLORBLIND_MODES lists none + the 8 cases", function()
  t.eq(#Theme.COLOR_CHOICES, 15)
  t.eq(#Theme.COLORBLIND_MODES, 9)
  t.eq(Theme.COLORBLIND_MODES[1][1], "none")
end)

t.test("buildTheme: black bg everywhere, font fg, button colour + orange-on-disabled buttons", function()
  local th = Theme.buildTheme({ font = "green", button = "darkGray" })
  t.eq(th.default.background, colors.black)
  t.eq(th.BaseFrame.background, colors.black)
  t.eq(th.BaseFrame.foreground, colors.green)
  t.eq(th.BaseFrame.Label.foreground, colors.green)
  t.eq(th.BaseFrame.Button.background, colors.gray)                        -- darkGray = CC gray
  t.eq(th.BaseFrame.Button.foreground, colors.green)
  t.eq(th.BaseFrame.Button.states.disabled.foreground, colors.orange)     -- inert buttons = orange text
  t.eq(th.BaseFrame.Button.states.disabled.background, colors.gray)
  t.eq(th.BaseFrame.Container.background, colors.black)
  -- nested containers stay black to ANY depth (self-referential Container node)
  t.eq(th.BaseFrame.Container.Container, th.BaseFrame.Container)
  t.eq(th.BaseFrame.Container.Container.Container.background, colors.black)
end)

t.test("paletteFor: base always recolours the lightRed (brown) slot", function()
  local pal = Theme.paletteFor(nil)
  t.eq(pal[colors.brown], 0xff6a6a)
end)

t.test("paletteFor: achromatopsia greys the colour slots (equal r=g=b)", function()
  local pal = Theme.paletteFor({ colorblind = "achromatopsia" })
  local g = pal[colors.green]
  t.truthy(type(g) == "number", "green slot remapped")
  local r = math.floor(g / 65536) % 256
  local gg = math.floor(g / 256) % 256
  local b = g % 256
  t.eq(r, gg); t.eq(gg, b)   -- pure gray
end)

t.test("paletteFor: a red-green mode shifts red off its default", function()
  local pal = Theme.paletteFor({ colorblind = "deuteranopia" })
  t.truthy(pal[colors.red] ~= nil and pal[colors.red] ~= Theme.DEFAULT_RGB[colors.red], "red remapped")
end)
