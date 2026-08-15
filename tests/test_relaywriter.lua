package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local RelayWriter = require("ui.relaywriter")

local function mockRelay()
  local calls = {}
  return {
    calls = calls,
    setOutput = function(side, val) calls[#calls + 1] = { side = side, val = val } end,
  }
end

t.test("writes the signal to the currently-configured side", function()
  local relay = mockRelay()
  local side = "back"
  local w = RelayWriter.make(function() return relay end, function() return side end)
  t.eq(w(true), true, "write succeeds")
  t.eq(#relay.calls, 1, "one write")
  t.eq(relay.calls[1].side, "back"); t.eq(relay.calls[1].val, true)
end)

t.test("clears the ABANDONED side to off when the configured side changes", function()
  -- The side-latching fix: after moving the side, the old side must not stay stuck at its last value.
  local relay = mockRelay()
  local side = "back"
  local w = RelayWriter.make(function() return relay end, function() return side end)
  w(true)          -- drive back = HIGH
  side = "front"   -- side reconfigured (as _pickSide would do, then blockNow forces this next write)
  w(false)         -- release "back", then drive "front"
  t.eq(#relay.calls, 3, "old-side release + new-side write")
  t.eq(relay.calls[2].side, "back");  t.eq(relay.calls[2].val, false, "old side released to off")
  t.eq(relay.calls[3].side, "front"); t.eq(relay.calls[3].val, false, "new side driven")
end)

t.test("no side-clear when the side is unchanged (write-through only)", function()
  local relay = mockRelay()
  local w = RelayWriter.make(function() return relay end, function() return "back" end)
  w(true); w(false); w(true)
  t.eq(#relay.calls, 3, "three plain writes, no spurious clears")
  for _, c in ipairs(relay.calls) do t.eq(c.side, "back") end
end)

t.test("no relay -> returns false and writes nothing", function()
  local w = RelayWriter.make(function() return nil end, function() return "back" end)
  t.eq(w(true), false)
end)

t.test("a throwing setOutput is caught and reported as failure", function()
  local relay = { setOutput = function() error("relay gone") end }
  local w = RelayWriter.make(function() return relay end, function() return "back" end)
  t.eq(w(true), false, "pcall-guarded, returns false rather than propagating")
end)
