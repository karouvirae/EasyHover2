-- ui/fedtrack.lua -- solid-fuel-fed tracker. PURE (no Basalt/peripherals). The engine feeds solid
-- fuel rarely (default intervalMs ~5.5 min apart; one blaze cake burns long), so the 3s pump poll is
-- flat between feeds and drops once per feed; a poll-to-poll DECREASE is the last feed's amount.
-- Increases (refills) or flat readings never read as a feed, so the last fed value persists until the
-- next feed. Fed from ui/basalt/app.lua's existing fuel poll -- no extra peripheral reads.
local FedTrack = {}
FedTrack.__index = FedTrack

function FedTrack.new() return setmetatable({ prev = nil, lfed = nil }, FedTrack) end

-- Feed one polled solid-pump amount. Returns the current last-fed amount (nil until the first drop).
function FedTrack:poll(amount)
  if type(amount) ~= "number" then return self.lfed end
  if self.prev and amount < self.prev then self.lfed = self.prev - amount end
  self.prev = amount
  return self.lfed
end

function FedTrack:lastFed() return self.lfed end

return FedTrack
