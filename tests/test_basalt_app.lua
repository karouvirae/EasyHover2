-- tests/test_basalt_app.lua
-- Headless probe (REAL CraftOS-PC): Basalt loads from the staged /release/basalt-full.lua,
-- and M.buildFrames constructs a frame per (mocked) monitor + one terminal frame, mirroring
-- honored, and a single basalt.update(...) render pass does not error.
local t = require("tests.framework")
local M = require("ui.basalt.app")

-- Minimal mock monitor/term: covers every term method release/basalt-full.lua's render path
-- (render.lua: setCursorPos/blit/setTextColor/setCursorBlink; BaseFrame's "term" setter:
-- setCursorPos presence gate + getSize) invokes, plus the rest of the CC:T monitor surface
-- listed in the task brief so any incidental call is a harmless no-op rather than a crash.
local function newMockMonitor()
  return {
    setCursorPos = function() end,
    write = function() end,
    blit = function() end,
    setTextColor = function() end,
    setTextColour = function() end,
    setBackgroundColor = function() end,
    setBackgroundColour = function() end,
    getSize = function() return 30, 12 end,
    clear = function() end,
    clearLine = function() end,
    setCursorBlink = function() end,
    isColor = function() return true end,
    isColour = function() return true end,
    getTextScale = function() return 1 end,
    setTextScale = function() end,
    scroll = function() end,
    getCursorPos = function() return 1, 1 end,
  }
end

t.test("ensureBasalt loads the vendored release build headless", function()
  local basalt = M.ensureBasalt()
  t.truthy(type(basalt) == "table", "basalt module should be a table")
  t.truthy(type(basalt.createFrame) == "function", "basalt.createFrame should exist")
  t.truthy(type(basalt.getMainFrame) == "function", "basalt.getMainFrame should exist")
  t.truthy(type(basalt.update) == "function", "basalt.update should exist")
end)

t.test("buildFrames creates a frame per assigned monitor (mirrored) plus a terminal frame", function()
  local basalt = M.ensureBasalt()
  local mocks = { mA = newMockMonitor(), mB = newMockMonitor() }
  local wrap = function(name) return mocks[name] end

  local built = M.buildFrames(basalt, { mA = 1, mB = 1 }, { "mA", "mB" }, wrap)

  t.truthy(built.terminal ~= nil, "terminal frame should exist")
  t.truthy(built.monitors.mA ~= nil, "mA frame entry should exist")
  t.truthy(built.monitors.mB ~= nil, "mB frame entry should exist")
  t.truthy(built.monitors.mA.frame ~= nil, "mA should have a frame")
  t.truthy(built.monitors.mB.frame ~= nil, "mB should have a frame")
  t.eq(built.monitors.mA.panelId, 1)
  t.eq(built.monitors.mB.panelId, 1)   -- mirrored onto the same panel id
  t.eq(#built.resolved.unassigned, 0)

  -- ONE render pass across every active frame (terminal + both mocked monitors). NEVER
  -- basalt.run() here -- that blocks on os.pullEventRaw() in a loop.
  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("buildFrames leaves unassigned present monitors out of the assigned set", function()
  local basalt = M.ensureBasalt()
  local mocks = { mA = newMockMonitor(), mC = newMockMonitor() }
  local wrap = function(name) return mocks[name] end

  local built = M.buildFrames(basalt, { mA = 1 }, { "mA", "mC" }, wrap)

  t.truthy(built.monitors.mA ~= nil, "mA should be built")
  t.truthy(built.monitors.mC == nil, "mC has no assignment, should not get a frame")
  t.eq(#built.resolved.unassigned, 1)
  t.eq(built.resolved.unassigned[1], "mC")
end)
