-- tests/test_input_events.lua
-- Hybrid typewriter input: event pre-apply + polled authority (fcs/input/events.lua).
local t = require("tests.framework")
local Events = require("fcs.input.events")
local keymap = require("fcs.input.keymap")

-- A tiny explicit map (code -> binding), independent of keys.* scancodes.
local MAP = {
  [200] = { axis = "lift", dir = 1 },    -- -> up
  [208] = { axis = "lift", dir = -1 },   -- -> down
  [203] = { axis = "yaw", dir = -1 },    -- -> yawLeft
}
local function rig(codes)
  local heldRef = { held = {} }
  local e = Events.new({
    codes = function() return codes end,
    map = function() return MAP end,
    held = heldRef.held,
  })
  return e, heldRef.held, function(list) codes = list end
end

t.test("a typewriter key press applies its flag immediately", function()
  local e, held = rig({ 200 })
  t.eq(held.up, nil)
  t.truthy(e:event("key", 200, true), "consumed")
  t.eq(held.up, true)
end)

t.test("typewriter press with arg2=false still applies when the code is in the pressed set", function()
  -- Simulated 1.3.0 queues ("key", code, entry.isAlive()) BEFORE activateKey, so a fresh
  -- press is boolean false. CC 1.120.0 local terminal key is also (code, boolean isRepeat).
  -- Arg2 type cannot discriminate; membership in getPressedKeyCodes can.
  local e, held = rig({ 200 })
  t.truthy(e:event("key", 200, false), "consumed")
  t.eq(held.up, true)
end)

t.test("key_up clears the flag without requiring membership in the pressed set", function()
  -- releaseKey REMOVES the code from pressedKeys before queueing the event, so a genuine
  -- release is always already absent from getPressedKeyCodes at delivery time.
  local e, held = rig({})
  held.up = true
  t.truthy(e:event("key_up", 200), "consumed")
  t.eq(held.up, nil)
end)

t.test("a press whose code is NOT in the device's pressed set is rejected (collision guard)", function()
  -- CC local key is also (int, boolean). A local scancode is not in the typewriter pressed
  -- set, so membership — not arg2's type — is the press discriminator.
  local e, held = rig({})      -- device reports nothing pressed
  t.eq(e:event("key", 200, false), false)
  t.eq(e:event("key", 200, true), false)
  t.eq(held.up, nil)
end)

t.test("onOsEvent applies a raw pullEvent tuple", function()
  local e, held = rig({ 200 })
  t.truthy(e:onOsEvent({ "key", 200, false }), "consumed")
  t.eq(held.up, true)
  t.eq(e:onOsEvent({ "timer", 1 }), false, "non-key ignored")
end)

t.test("unbound codes and non-key events are ignored", function()
  local e, held = rig({ 200 })
  t.eq(e:event("key", 21, true), false, "unbound code")
  t.eq(e:event("modem_message", 1, 2, 3), false, "other events pass through unconsumed")
  t.eq(e:event("char", "w"), false)
  t.eq(next(held), nil)
end)

t.test("sync rebuilds the held table IN PLACE from the device snapshot", function()
  -- In-place matters: the control task holds the same table reference across cycles.
  local e, held, setCodes = rig({ 200 })
  e:sync()
  t.eq(held.up, true)
  setCodes({ 208 })            -- pilot released W, holds S
  e:event("key_up", 200)       -- event path clears first...
  t.eq(held.up, nil)
  e:sync()                     -- ...poll confirms authoritatively
  t.eq(held.down, true)
  local sameTable = true
  setCodes({})
  e:sync()
  for _ in pairs(held) do sameTable = false end
  t.truthy(sameTable ~= nil, "table identity preserved (mutated, not replaced)")
end)

t.test("integration with the real default keymap: WASD codes resolve through flagFor", function()
  local heldRef = { held = {} }
  local codes = { keys.w, keys.q }
  local e = Events.new({
    codes = function() return codes end,
    map = function() return keymap.forMode("PRECISION") end,
    held = heldRef.held,
  })
  e:sync()
  t.eq(heldRef.held.surgeFwd, true); t.eq(heldRef.held.yawLeft, true)
  t.truthy(e:event("key_up", keys.q), "real-map release consumed")
  t.eq(heldRef.held.yawLeft, nil); t.eq(heldRef.held.surgeFwd, true, "other flag untouched")
end)
