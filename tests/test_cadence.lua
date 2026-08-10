package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local G = require("ui.basalt.cadence")

t.test("gate ignores sub-quantum jitter, catches a visible change + uiRev", function()
  local base = { altitude = 10.00, uiRev = 0, mode = "HOVER" }
  local _, s0 = G.gate(nil, base)
  t.eq(select(1, G.gate(s0, { altitude = 10.004, uiRev = 0, mode = "HOVER" })), false, "0.4cm jitter -> no repaint")
  t.eq(select(1, G.gate(s0, { altitude = 10.2,   uiRev = 0, mode = "HOVER" })), true,  "20cm -> repaint")
  t.eq(select(1, G.gate(s0, { altitude = 10.00,  uiRev = 1, mode = "HOVER" })), true,  "config edit (uiRev) -> repaint")
end)

t.test("raw fuel amounts (pumpAmount/tankMb) are in the signature", function()
  local base = { pumpAmount = 100, tankMb = 4200 }
  local _, s0 = G.gate(nil, base)
  t.eq(select(1, G.gate(s0, { pumpAmount = 100, tankMb = 4200 })), false, "no change -> no repaint")
  t.eq(select(1, G.gate(s0, { pumpAmount = 99,  tankMb = 4200 })), true,  "solid count change -> repaint")
  t.eq(select(1, G.gate(s0, { pumpAmount = 100, tankMb = 4201 })), true,  "liquid mB change -> repaint")
end)
