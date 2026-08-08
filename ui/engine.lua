--[[ UI-side engine pulse machine: drives the fuel chute relay over an injected writer.

     THE INVERSION IS THE WHOLE POINT. The funnel above the engine passes items only while it
     is UNPOWERED, so holding the redstone HIGH blocks it and dropping the signal briefly lets
     exactly one item through. That inverts everything you would expect:

       master OFF -> funnel held blocked, continuously. Nothing feeds the engine, the vehicle
                     is off. This is also the state at boot, and the state we fall back to on
                     any error -- an engine that will not start is a much better failure than a
                     funnel that empties the whole vault into it.
       master ON  -> one interrupt pulse immediately (the kickstart), then an interrupt every
                     `intervalMs` to feed one more item and keep it running.

     Timings are configurable because they depend on the build: `pulseMs` must be long enough
     for one item to pass and short enough that a second cannot follow, and `intervalMs` must
     be shorter than the engine's burn time.

     `writer(on)` is the ONLY impure edge: it performs the actual relay write. By default the
     writer is told `on = feeding` (true = let an item through). `invert` flips that polarity
     for a build wired the other way round -- everything else below is written in terms of
     "blocked" and "feeding" rather than high and low, so the inversion lives in exactly one
     place: `_write`.

     Ported from EasyHover 1's flight/lib/io/engine.lua. Retargeted for the UI PC: the physical
     write is an injected `writer(on)` closure instead of a direct peripheral call, and there is
     no log/state/available() -- those belonged to the flight-side peripheral registry. `now` is
     always passed in; this module never calls os.epoch itself.
]]

local Engine = {}
Engine.__index = Engine

function Engine.new(cfg, writer)
  local self = setmetatable({}, Engine)
  self.cfg = cfg
  self.writer = writer

  self.master = cfg.masterDefault and true or false
  self.feeding = false          -- true while the funnel is being allowed to pass an item
  self.pulseEndsAt = nil
  self.nextPulseAt = nil
  self.pulses = 0
  self.lastWritten = nil        -- what we last told the relay, for write-on-change
  return self
end

--- Write the physical output. `feeding` true means "let an item through".
-- The single place the inversion is applied.
function Engine:_write(feeding)
  if self.lastWritten == feeding then return true end

  local signal = feeding                -- writer sees "let it through", by default
  if self.cfg.invert then signal = not signal end

  self.writer(signal)
  self.lastWritten = feeding
  self.feeding = feeding
  return true
end

--- Turn the vehicle on or off. Returns the new master state.
function Engine:setMaster(on, now)
  on = on and true or false
  if on == self.master then return self.master end
  self.master = on

  if not on then
    -- Off: block the funnel and hold it blocked. No pending pulse survives.
    self.pulseEndsAt, self.nextPulseAt = nil, nil
    self:_write(false)
  else
    if self.cfg.kickstart then
      self:_startPulse(now)
    else
      self:_write(false)
      self.nextPulseAt = now + self.cfg.intervalMs
    end
  end
  return self.master
end

function Engine:toggleMaster(now)
  return self:setMaster(not self.master, now)
end

function Engine:_startPulse(now)
  self.pulseEndsAt = now + self.cfg.pulseMs
  self.nextPulseAt = nil
  self.pulses = self.pulses + 1
  self:_write(true)
end

--- Call once per control cycle. Drives the pulse state machine.
function Engine:tick(now)
  if not self.master then
    -- Held blocked. Re-assert rather than assume: a rescan or a relay reboot could have
    -- dropped the output, and an unblocked funnel with the master off would quietly drain
    -- the vault.
    self:_write(false)
    return
  end

  if self.pulseEndsAt then
    if now >= self.pulseEndsAt then
      self.pulseEndsAt = nil
      self.nextPulseAt = now + self.cfg.intervalMs
      self:_write(false)
    end
    return
  end

  if self.nextPulseAt and now >= self.nextPulseAt then
    self:_startPulse(now)
    return
  end

  if not self.nextPulseAt then
    self.nextPulseAt = now + self.cfg.intervalMs
  end
  self:_write(false)
end

--- Force a feed now, without waiting for the interval. For a manual "prime" button.
function Engine:feedNow(now)
  if not self.master then return false, "engine master is off" end
  self:_startPulse(now)
  return true
end

--- Put the output back to blocked. Called on shutdown and on hardware change.
function Engine:blockNow()
  self.pulseEndsAt, self.nextPulseAt = nil, nil
  self.lastWritten = nil          -- force the write
  return self:_write(false)
end

function Engine:status(now)
  local remaining = nil
  if self.master and self.nextPulseAt then
    remaining = math.max(0, self.nextPulseAt - now)
  end
  return {
    master = self.master,
    feeding = self.feeding,
    pulses = self.pulses,
    nextFeedInMs = remaining,
    pulseMs = self.cfg.pulseMs,
    intervalMs = self.cfg.intervalMs,
  }
end

function Engine:applyConfig(cfg)
  self.cfg = cfg
  self.lastWritten = nil
end

return Engine
