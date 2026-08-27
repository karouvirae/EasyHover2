-- fcs/input/events.lua
-- Typewriter input: event pre-apply on the control pull + filtered poll as heal.
--
-- Simulated 1.3.0 LinkedTypewriterBlockEntity.pressKey/releaseKey queueEvent to every
-- attached IComputerAccess (including WiredModemPeripheral.RemotePeripheralWrapper).
-- CC 1.120.0 EventComputerInput.keyDown is also ("key", int, boolean isRepeat) — same
-- shape as typewriter ("key", int, isAlive-before-activate). Discriminator is membership
-- in getPressedKeyCodes() on press, not arg2's type. key_up cannot use membership
-- (releaseKey removes first); a colliding local key_up is healed by the 50 ms poll.
--
-- Apply events from controlTask: that coroutine is already an unfiltered os.pullEvent()
-- and already wakes on key/key_up. Do NOT add a second unfiltered input loop.
-- Do NOT filter control to os.pullEvent("timer") either — CC pullEvent takes one name, so
-- a timer-only filter would drop typewriter events (incompatible with that filter as written).
--
-- Press-path self.codes() is getPressedKeyCodes: @LuaFunction default mainThread=false
-- (computer-thread list read). If that annotation ever becomes mainThread=true, this call
-- on the control coroutine stalls the flight loop — do not add it to the step pcall.
local keymap = require("fcs.input.keymap")

local E = {}
E.__index = E

function E.new(deps)
  -- deps.codes() -> current pressed-code list from the device (never nil)
  -- deps.map()   -> active code->binding table (keymap.forMode(flightMode))
  -- deps.held    -> the SHARED held-flag table the control loop reads; mutated IN PLACE so the
  --                 reference the control task holds never goes stale
  return setmetatable({ codes = deps.codes, map = deps.map, held = deps.held }, E)
end

-- Returns true when the event was consumed as craft input.
function E:event(name, code, _)
  if name ~= "key" and name ~= "key_up" then return false end
  if type(code) ~= "number" then return false end
  if name == "key" then
    -- pressKey adds to pressedKeys BEFORE queueing. CC local keyDown does not. Membership
    -- is the press discriminator (both sources use a boolean arg2).
    local present = false
    for _, c in ipairs(self.codes()) do
      if c == code then present = true break end
    end
    if not present then return false end
  end
  -- key_up skips membership: releaseKey removes the code before queueing.
  local flag = keymap.flagFor(self.map(), code)
  if not flag then return false end
  self.held[flag] = (name == "key") or nil
  return true
end

function E:onOsEvent(ev)
  return self:event(ev[1], ev[2], ev[3])
end

-- Authoritative rebuild from the device snapshot; replaces contents in place.
function E:sync()
  local resolved = keymap.resolve(self.map(), self.codes())
  for k in pairs(self.held) do self.held[k] = nil end
  for k, v in pairs(resolved) do self.held[k] = v end
end

return E
