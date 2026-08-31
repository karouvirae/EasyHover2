local t = require("tests.framework")
local cut = require("fcs.io.cut")

t.test("isThrusterType: thruster type strings only", function()
  t.eq(cut.isThrusterType("thruster"), true)
  t.eq(cut.isThrusterType("vector_thruster"), true)
  t.eq(cut.isThrusterType("solid_fuel_thruster"), true)
  t.eq(cut.isThrusterType("ion_thruster"), true)
  t.eq(cut.isThrusterType("modem"), false)
  t.eq(cut.isThrusterType("monitor"), false)
  t.eq(cut.isThrusterType("altitude_sensor"), false)
  t.eq(cut.isThrusterType("redstone_relay"), false)
  t.eq(cut.isThrusterType(nil), false)
end)

t.test("names: keeps thruster types, drops everything else", function()
  local names = { "left", "modem_0", "thr_1", "baro", "relay" }
  local types = {
    left = "vector_thruster",
    modem_0 = "modem",
    thr_1 = "thruster",
    baro = "altitude_sensor",
    relay = "redstone_relay",
  }
  local got = cut.names(function() return names end, function(n) return types[n] end)
  t.eq(#got, 2)
  t.eq(got[1], "left")
  t.eq(got[2], "thr_1")
end)

t.test("zero: writes setPower(0) on each wrapped thruster", function()
  local power = {}
  local wrap = function(name)
    return { setPower = function(v) power[name] = v end }
  end
  local n = cut.zero(wrap, { "a", "b" })
  t.eq(n, 2)
  t.eq(power.a, 0)
  t.eq(power.b, 0)
end)

t.test("zero: falls back to setThrust(0) when setPower is absent", function()
  local thrust
  local wrap = function()
    return { setThrust = function(v) thrust = v end }
  end
  cut.zero(wrap, { "x" })
  t.eq(thrust, 0)
end)

t.test("zero: a throwing write does not skip the rest", function()
  local ok
  local wrap = function(name)
    if name == "bad" then
      return { setPower = function() error("nope") end }
    end
    return { setPower = function(v) ok = v end }
  end
  cut.zero(wrap, { "bad", "good" })
  t.eq(ok, 0)
end)

t.test("zero: n>1 uses injected dispatch", function()
  local seen = 0
  local dispatch = function(fns)
    seen = #fns
    for i = 1, #fns do fns[i]() end
  end
  local wrap = function()
    return { setPower = function() end }
  end
  cut.zero(wrap, { "a", "b", "c" }, dispatch)
  t.eq(seen, 3)
end)

t.test("all: no peripheral API is a no-op", function()
  local n = cut.all({ getNames = nil, getType = nil, wrap = nil })
  t.eq(n, 0)
end)

t.test("all: discovers via opts and zeros", function()
  local power = {}
  local n = cut.all({
    getNames = function() return { "t0", "m0" } end,
    getType = function(n) return n == "t0" and "thruster" or "modem" end,
    wrap = function(name)
      return { setPower = function(v) power[name] = v end }
    end,
  })
  t.eq(n, 1)
  t.eq(power.t0, 0)
  t.eq(power.m0, nil)
end)
