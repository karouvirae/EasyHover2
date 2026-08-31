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

local function readAll(path)
  local f = fs.open(path, "r")
  t.truthy(f, "missing " .. path)
  local body = f.readAll() or ""
  f.close()
  return body
end

local function firstPos(body, needle)
  local i = body:find(needle, 1, true)
  t.truthy(i, "expected to find " .. needle)
  return i
end

t.test("launchers/fcs.lua cuts before the boot loader", function()
  local body = readAll("/launchers/fcs.lua")
  local cutAt = firstPos(body, "fcs.io.cut")
  local bootAt = firstPos(body, "loaderui")
  t.truthy(cutAt < bootAt, "cut must run before loaderui")
end)

t.test("launchers/flight.lua cuts before tools.flight", function()
  local body = readAll("/launchers/flight.lua")
  local cutAt = firstPos(body, "fcs.io.cut")
  local flightAt = firstPos(body, "tools.flight")
  t.truthy(cutAt < flightAt, "cut must run before tools.flight")
end)

t.test("tools/flight.lua cuts at process start and in safeShutdown", function()
  local body = readAll("/tools/flight.lua")
  local startAt = firstPos(body, "package.path")
  firstPos(body, "fcs.io.cut")
  -- Source keeps `cut.all`; luamin renames the local so dist has `<id>.all)`.
  local firstCut = body:find("cut.all", 1, true) or body:find(".all)", 1, true)
  t.truthy(firstCut, "expected cut.all (or minified .all)")
  local loadAt = body:find("loadConfig", 1, true)
    or body:find("Backend.new", 1, true)
    or body:find("fcs.io.hwconfig", 1, true)
  t.truthy(loadAt, "expected loadConfig/Backend or hwconfig require")
  t.truthy(firstCut > startAt and firstCut < loadAt, "cut.all before config/backend")
  local shut = body:find("local function safeShutdown", 1, true)
  local shutCut
  if shut then
    shutCut = body:find("cut.all", shut, true) or body:find(".all)", shut, true)
  else
    -- minified: local name gone; second .all) is the shutdown cut
    shutCut = body:find(".all)", firstCut + 1, true)
  end
  t.truthy(shutCut, "safeShutdown calls cut.all")
end)

t.test("tools/hover_test.lua run() cuts before baseline", function()
  local body = readAll("/tools/hover_test.lua")
  t.truthy(body:find("fcs.io.cut", 1, true), "hover_test must require fcs.io.cut")
  -- Source: `cut.all` inside `run`. Dist: luamin renames locals (`run`, `cut`, `baseline`).
  local cutAt = body:find("cut.all", 1, true) or body:find(".all)", 1, true)
  t.truthy(cutAt, "run() must call cut")
  -- Print string survives minify; `baseline(` does not (local renamed).
  local baseAt = body:find("measuring baseline", 1, true)
  if not baseAt then
    local runAt = body:find("local function run", 1, true)
    if runAt then baseAt = body:find("baseline(", runAt, true) end
  end
  t.truthy(baseAt, "run() must reach baseline")
  t.truthy(cutAt < baseAt, "cut before baseline")
end)
