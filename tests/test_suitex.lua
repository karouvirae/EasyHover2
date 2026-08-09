package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
_G.EH2_SUITEX_NO_RUN = true
local SuiteX = require("easyhover2_suitex")

t.test("suitex loads as a library without running the UI", function()
  t.eq(type(SuiteX), "table")
end)
