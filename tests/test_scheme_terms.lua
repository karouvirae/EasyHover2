local t = require("tests.framework")
local Level = require("fcs.schemes.level_flight")
local Manual = require("fcs.schemes.manual")

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
           swayPos = 0.5, surgePos = -0.5, swayVel = 0.1, surgeVel = -0.1 }
end

local function isFinite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

t.test("Scheme:terms assembles all 6 axes with err/P/I/D after one update", function()
  local sc = Level.new(cfg())
  local s, mm = sp(), m()
  sc:update(s, mm, 0.1, false, {})
  local terms = sc:terms(s, mm)
  for _, axis in ipairs({ "alt", "pitch", "roll", "yaw", "sway", "surge" }) do
    local ax = terms[axis]
    t.truthy(ax, axis .. " axis present")
    t.truthy(isFinite(ax.err), axis .. ".err finite")
    t.truthy(isFinite(ax.P), axis .. ".P finite")
    t.truthy(isFinite(ax.I), axis .. ".I finite")
    t.truthy(isFinite(ax.D), axis .. ".D finite")
  end
end)

t.test("Scheme:terms alt.I matches the live altPid integrator state", function()
  local sc = Level.new(cfg())
  local s, mm = sp(), m()
  sc:update(s, mm, 0.1, false, {})
  local terms = sc:terms(s, mm)
  t.eq(terms.alt.I, sc.altPid.i, "alt.I reflects altPid.i")
end)

t.test("Scheme:terms pitch axis P+I+D sums to a finite number", function()
  local sc = Level.new(cfg())
  local s, mm = sp(), m()
  sc:update(s, mm, 0.1, false, {})
  local terms = sc:terms(s, mm)
  local sum = terms.pitch.P + terms.pitch.I + terms.pitch.D
  t.truthy(isFinite(sum), "pitch P+I+D finite")
end)

t.test("Scheme:terms is pure -- does not mutate controller state", function()
  local sc = Level.new(cfg())
  local s, mm = sp(), m()
  sc:update(s, mm, 0.1, false, {})
  local iBefore = sc.altPid.i
  sc:terms(s, mm)
  sc:terms(s, mm)
  t.eq(sc.altPid.i, iBefore, "altPid.i unchanged by repeated :terms calls")
end)

t.test("wrapper scheme reaches Scheme:terms via .inner (documents Task 3's path)", function()
  local w = Manual.new(cfg())
  local s, mm = sp(), m()
  w:update(s, mm, 0.1, false, {})
  local terms = w.inner:terms(s, mm)
  for _, axis in ipairs({ "alt", "pitch", "roll", "yaw", "sway", "surge" }) do
    t.truthy(terms[axis], "wrapper .inner:terms exposes " .. axis)
    t.truthy(isFinite(terms[axis].err), "wrapper .inner:terms " .. axis .. ".err finite")
  end
end)
