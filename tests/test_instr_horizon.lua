package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local H = require("ui.basalt.instruments.horizon")

t.test("row is exactly w chars for both styles and any width", function()
  for _, w in ipairs({ 1, 2, 7, 20, 41 }) do
    t.eq(#H.row(w, "ascii"), w, "ascii width " .. w)
    t.eq(#H.row(w, "subpixel"), w, "subpixel width " .. w)
  end
end)

t.test("ascii style is the '- ' dash pattern", function()
  t.eq(H.row(6, "ascii"), "- - - ", "repeats the ascii pair")
end)

t.test("defaults to ascii when style is missing or unknown", function()
  t.eq(H.row(6), H.row(6, "ascii"), "nil style -> ascii")
  t.eq(H.row(6, "bogus"), H.row(6, "ascii"), "unknown style -> ascii")
end)

t.test("subpixel style uses the named glyph constant", function()
  local g = H.STYLE.subpixel.pair
  t.eq(H.row(4, "subpixel"), g .. g, "repeats the subpixel pair")
end)
