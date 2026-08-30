-- tests/test_loop_diag.lua
local t = require("tests.framework")
local Loop = require("fcs.runtime.loop")
local Level = require("fcs.schemes.level_flight")
local Mixer = require("fcs.mixer.level_flight")

local function cfg()
  return {
    hoverDuty = 0.5,
    alt = { kp = 0.5, ki = 0.2, kd = 0.1, tauD = 0.2 },
    pitch = { kp = 0.4, ki = 0.3, kd = 0.05, tauD = 0.2 },
    roll = { kp = 0.4, ki = 0.3, kd = 0.05, tauD = 0.2 },
    yaw = { kp = 0.3, ki = 0.1, kd = 0.02 },
    sway = { kp = 0.2, ki = 0.1, kd = 0.05 },
    surge = { kp = 0.2, ki = 0.1, kd = 0.05 },
  }
end

local function sp()
  return { altitude = 5, pitch = 0.1, roll = -0.1, heading = 0.2,
           swayPos = 1, surgePos = -1 }
end

local function m()
  return { altitude = 2, pitch = 0.05, roll = 0.02, heading = 0.1, yawRate = 0.01,
           swayVel = 0.1, surgeVel = -0.1, swayPos = 0.5, surgePos = -0.5, onGround = false }
end

local function fakeBackend()
  return { sensors = function() return m() end }
end
local function fakePwm() return { apply = function() end } end

local function build()
  local level = Level.new(cfg())
  local loop = Loop.new({ scheme = level, mixer = Mixer.new(), pwm = fakePwm(),
    backend = fakeBackend(), caps = { pitch = 1, roll = 1, yaw = 1, sway = 1, surge = 1 } })
  return loop, level
end

t.test("diag: terms.pitch present with err/P/I/D after a cycle", function()
  local loop = build()
  loop:arm(true)
  loop:setTrim(1, 0.2)
  loop:setpoints(sp())
  loop:cycle(0.1, m())
  local d = loop:diag(sp(), m())
  t.truthy(d.terms, "terms present")
  t.truthy(d.terms.pitch, "terms.pitch present")
  t.truthy(type(d.terms.pitch.err) == "number", "terms.pitch.err numeric")
  t.truthy(type(d.terms.pitch.P) == "number", "terms.pitch.P numeric")
  t.truthy(type(d.terms.pitch.I) == "number", "terms.pitch.I numeric")
  t.truthy(type(d.terms.pitch.D) == "number", "terms.pitch.D numeric")
end)

t.test("diag: sat is a table, trimDir/trimGain reflect setTrim", function()
  local loop = build()
  loop:arm(true)
  loop:setTrim(1, 0.2)
  loop:setpoints(sp())
  loop:cycle(0.1, m())
  local d = loop:diag(sp(), m())
  t.truthy(type(d.sat) == "table", "sat is a table")
  t.eq(d.trimDir, 1, "trimDir reflects setTrim")
  t.near(d.trimGain, 0.2, 1e-9, "trimGain reflects setTrim")
  t.truthy(type(d.heaveBanded) == "boolean", "heaveBanded is boolean")
end)

t.test("diag: resolves the Level directly (no .inner) for PRECISION/LDG-style schemes", function()
  local loop, level = build()
  loop:arm(true)
  loop:setpoints(sp())
  loop:cycle(0.1, m())
  local d = loop:diag(sp(), m())
  t.eq(d.terms.alt.I, level.altPid.i, "diag.terms.alt.I matches live altPid.i")
end)

t.test("diag: pure read -- does not mutate controller state or self._sat", function()
  local loop = build()
  loop:arm(true)
  loop:setTrim(1, 0.2)
  loop:setpoints(sp())
  loop:cycle(0.1, m())
  loop:cycle(0.1, m())   -- populate self._sat from envelope.clamp
  local iBefore = loop.scheme.altPid.i
  local satBefore = {}
  for k, v in pairs(loop._sat or {}) do satBefore[k] = v end

  loop:diag(sp(), m())
  loop:diag(sp(), m())

  t.eq(loop.scheme.altPid.i, iBefore, "altPid.i unchanged by repeated :diag calls")
  local satAfter = loop._sat or {}
  for k, v in pairs(satBefore) do t.eq(satAfter[k], v, "sat entry " .. tostring(k) .. " unchanged") end
  local n = 0
  for _ in pairs(satAfter) do n = n + 1 end
  local nBefore = 0
  for _ in pairs(satBefore) do nBefore = nBefore + 1 end
  t.eq(n, nBefore, "sat table size unchanged")
end)

t.test("diag: nil-safe before any cycle (no self._sat yet)", function()
  local loop = build()
  local ok, d = pcall(function() return loop:diag(sp(), m()) end)
  t.truthy(ok, "diag does not error before any cycle")
  t.truthy(type(d.sat) == "table", "sat defaults to a table")
  t.eq(d.trimDir, 0, "trimDir defaults to 0")
  t.eq(d.trimGain, 0, "trimGain defaults to 0")
end)
