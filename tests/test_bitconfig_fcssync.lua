-- tests/test_bitconfig_fcssync.lua
-- FCS SYNC sub-menu (ui/basalt/bitconfig/fcssync.lua): tests the PURE M.linkStatus function,
-- the M._onButton handler, and a real-CraftOS-PC Basalt construction probe.
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.fcssync")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")

-- ===== M.id / M.title: canonical identifiers =====

t.test("id and title: correctly set for the FCS SYNC screen", function()
  t.eq(M.id, "fcssync")
  t.eq(M.title, "FCS SYNC")
end)

-- ===== M.FRESH_MS: freshness threshold =====

t.test("FRESH_MS: set to 3000 ms", function()
  t.eq(M.FRESH_MS, 3000)
end)

-- ===== M.linkStatus: PURE link-status logic =====

t.test("linkStatus: server stopped -> STOPPED", function()
  local status = { running = false, lastSeen = nil }
  local now = 1000
  local result = M.linkStatus(status, now)
  t.eq(result, "STOPPED")
end)

t.test("linkStatus: server running, lastSeen fresh (within FRESH_MS) -> FCS ACTIVE", function()
  local status = { running = true, lastSeen = 1000 }
  local now = 1000 + 1000  -- 1000 ms elapsed < 3000 ms
  local result = M.linkStatus(status, now)
  t.eq(result, "FCS ACTIVE")
end)

t.test("linkStatus: server running, lastSeen fresh at boundary (exactly FRESH_MS) -> FCS ACTIVE", function()
  local status = { running = true, lastSeen = 1000 }
  local now = 1000 + M.FRESH_MS  -- exactly at threshold
  local result = M.linkStatus(status, now)
  t.eq(result, "FCS ACTIVE")
end)

t.test("linkStatus: server running, lastSeen stale (> FRESH_MS) -> WAITING FOR FCS", function()
  local status = { running = true, lastSeen = 1000 }
  local now = 1000 + M.FRESH_MS + 1  -- just over threshold
  local result = M.linkStatus(status, now)
  t.eq(result, "WAITING FOR FCS")
end)

t.test("linkStatus: server running, lastSeen nil -> WAITING FOR FCS", function()
  local status = { running = true, lastSeen = nil }
  local now = 1000
  local result = M.linkStatus(status, now)
  t.eq(result, "WAITING FOR FCS")
end)

t.test("linkStatus: server stopped overrides lastSeen (even if fresh) -> STOPPED", function()
  local status = { running = false, lastSeen = 1000 }
  local now = 1000 + 100  -- fresh, but server stopped
  local result = M.linkStatus(status, now)
  t.eq(result, "STOPPED")
end)

-- ===== M._onButton: PURE button handler =====

t.test("_onButton: start button -> calls cfgserver:start() and bumps uiRev", function()
  local startCalled = false
  local runtime = {
    cfgserver = {
      start = function(self) startCalled = true end,
      stop = function(self) end,
    },
    uiRev = 0,
  }
  local result = M._onButton(runtime, "start", 1000)
  t.truthy(startCalled, "cfgserver:start() should have been called")
  t.eq(runtime.uiRev, 1, "uiRev should have been bumped")
  t.eq(result, "start", "should return the button id")
end)

t.test("_onButton: stop button -> calls cfgserver:stop() and bumps uiRev", function()
  local stopCalled = false
  local runtime = {
    cfgserver = {
      start = function(self) end,
      stop = function(self) stopCalled = true end,
    },
    uiRev = 5,
  }
  local result = M._onButton(runtime, "stop", 1000)
  t.truthy(stopCalled, "cfgserver:stop() should have been called")
  t.eq(runtime.uiRev, 6, "uiRev should have been bumped from 5 to 6")
  t.eq(result, "stop", "should return the button id")
end)

t.test("_onButton: unknown button -> no action, returns nil", function()
  local startCalled = false
  local stopCalled = false
  local runtime = {
    cfgserver = {
      start = function(self) startCalled = true end,
      stop = function(self) stopCalled = true end,
    },
    uiRev = 10,
  }
  local result = M._onButton(runtime, "unknown", 1000)
  t.truthy(not startCalled, "cfgserver:start() should NOT have been called")
  t.truthy(not stopCalled, "cfgserver:stop() should NOT have been called")
  t.eq(runtime.uiRev, 10, "uiRev should NOT have been bumped")
  t.eq(result, nil, "should return nil for unknown button")
end)

t.test("_onButton: start with uninitialized uiRev -> starts from 0 and bumps to 1", function()
  local runtime = {
    cfgserver = {
      start = function(self) end,
      stop = function(self) end,
    },
    -- uiRev not initialized
  }
  M._onButton(runtime, "start", 1000)
  t.eq(runtime.uiRev, 1, "uiRev should be initialized to 1")
end)

-- ===== Construction probe: real CraftOS-PC Basalt =====

t.test("M.build: constructs the element tree; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  local runtime = {
    cfgserver = {
      start = function(self) end,
      stop = function(self) end,
      status = function(self) return { running = false, lastSeen = nil } end,
    },
    uiRev = 0,
  }

  local h = M.build(basalt, frame, runtime, nav)
  t.eq(h.id, "fcssync")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.titleLabel ~= nil, "titleLabel present")
  t.truthy(h.elements.serverLbl ~= nil, "serverLbl present")
  t.truthy(h.elements.linkLbl ~= nil, "linkLbl present")
  t.truthy(h.elements.ssRow ~= nil and h.elements.ssRow.buttons[1] ~= nil, "START/STOP action row present")
  t.truthy(h.elements.backRow ~= nil, "back row present")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build: apply() updates labels based on running status", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  local runtime = {
    cfgserver = {
      start = function(self) end,
      stop = function(self) end,
      status = function(self) return { running = false, lastSeen = nil } end,
    },
    uiRev = 0,
  }

  local h = M.build(basalt, frame, runtime, nav)

  -- Initial apply: server stopped -- START enabled (off), STOP disabled
  h.apply({})
  t.eq(h.elements.serverLbl:getText(), "SERVER: STOPPED")
  t.eq(h.elements.linkLbl:getText(), "LINK: STOPPED")
  t.eq(h.elements.ssRow.buttons[1].state, "off", "START should be off (enabled) when stopped")
  t.eq(h.elements.ssRow.buttons[2].state, "disabled", "STOP should be disabled when stopped")

  -- Change status to running + fresh -- START disabled, STOP enabled (off)
  runtime.cfgserver.status = function(self)
    return { running = true, lastSeen = os.epoch("utc") - 1000 }
  end
  h.apply({})
  t.eq(h.elements.serverLbl:getText(), "SERVER: RUNNING")
  t.eq(h.elements.linkLbl:getText(), "LINK: FCS ACTIVE")
  t.eq(h.elements.ssRow.buttons[1].state, "disabled", "START should be disabled when running")
  t.eq(h.elements.ssRow.buttons[2].state, "off", "STOP should be off (enabled) when running")

  -- Change status to running + stale
  runtime.cfgserver.status = function(self)
    return { running = true, lastSeen = os.epoch("utc") - M.FRESH_MS - 1000 }
  end
  h.apply({})
  t.eq(h.elements.serverLbl:getText(), "SERVER: RUNNING")
  t.eq(h.elements.linkLbl:getText(), "LINK: WAITING FOR FCS")
end)

t.test("M.build: apply() idempotent across different statuses", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  local runtime = {
    cfgserver = {
      start = function(self) end,
      stop = function(self) end,
      status = function(self) return { running = false, lastSeen = nil } end,
    },
    uiRev = 0,
  }

  local h = M.build(basalt, frame, runtime, nav)

  -- When stopped
  h.apply({})
  t.eq(h.elements.serverLbl:getText(), "SERVER: STOPPED")

  -- When running
  runtime.cfgserver.status = function(self) return { running = true, lastSeen = os.epoch("utc") } end
  h.apply({})
  t.eq(h.elements.serverLbl:getText(), "SERVER: RUNNING")

  -- Multiple apply calls should be safe
  h.apply({})
  h.apply({})
  t.eq(h.elements.serverLbl:getText(), "SERVER: RUNNING")
end)

t.test("M.build: nav back integration", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  nav:push("fcssync")

  local runtime = {
    cfgserver = {
      start = function(self) end,
      stop = function(self) end,
      status = function(self) return { running = false, lastSeen = nil } end,
    },
    uiRev = 0,
  }

  local h = M.build(basalt, frame, runtime, nav)
  local beforeDepth = nav:depth()
  t.truthy(beforeDepth > 1, "nav stack should have more than one element")

  -- Simulate BACK button click via nav:pop()
  nav:pop()
  local afterDepth = nav:depth()
  t.eq(afterDepth, beforeDepth - 1, "nav stack should have one fewer element after pop")
end)

-- ===== B2: apply on open and START/STOP =====

t.test("M.build: paints SERVER/LINK on construct without the caller applying", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local runtime = {
    cfgserver = {
      start = function() end, stop = function() end,
      status = function() return { running = false, lastSeen = nil } end,
    },
    uiRev = 0,
  }
  local h = M.build(basalt, frame, runtime, Nav.new("bitconfig"))
  t.eq(h.elements.serverLbl:getText(), "SERVER: STOPPED")
  t.eq(h.elements.linkLbl:getText(), "LINK: STOPPED")
end)

t.test("START onClick applies after cfgserver:start", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local running = false
  local runtime = {
    cfgserver = {
      start = function() running = true end, stop = function() end,
      status = function() return { running = running, lastSeen = nil } end,
    },
    uiRev = 0,
  }
  local h = M.build(basalt, frame, runtime, Nav.new("bitconfig"))
  t.eq(h.elements.serverLbl:getText(), "SERVER: STOPPED")
  h.elements.ssRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(running, true)
  t.eq(h.elements.serverLbl:getText(), "SERVER: RUNNING")
  t.eq(h.elements.linkLbl:getText(), "LINK: WAITING FOR FCS")
end)

return t
