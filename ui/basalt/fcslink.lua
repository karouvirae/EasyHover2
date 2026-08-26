-- ui/basalt/fcslink.lua
-- Decides whether the FLIGHT feedback buttons should blink an "FCS signal missing" cue, and the blink
-- phase, from the FCS heartbeat freshness. PURE: no peripherals, no Basalt, no globals -- all times are
-- ms, injected. Two-phase so a UI booting next to an offline/booting FCS blinks QUICKLY (quick startup
-- recognition), but a live link that then drops is tolerated for a grace window (no flicker on lag).
local M = {}

-- Never-connected (no heartbeat seen since UI boot): blink after this long. Short, for quick startup
-- recognition -- but longer than the FCS's 1s heartbeat period so a live FCS's first beat always beats it.
M.BOOT_GRACE_MS = 1500
-- Was-connected then lost: blink only after this long since the last beat. ~4 missed 1s heartbeats --
-- tolerates lag / a stalled tick / brief drops without flickering the cue.
M.DROP_GRACE_MS = 4000
-- The outline toggles gray<->red every this many ms.
M.BLINK_HALF_MS = 500

-- evaluate(now, s) -> stale(bool), phase(0|1)
--   now: current time, ms.
--   s = { bootAt (ms, UI boot time), lastSeenMs (ms of last FCS heartbeat, or nil if none seen since boot),
--         bootGraceMs?, dropGraceMs?, blinkHalfMs? (overrides, else the M.* defaults) }
-- `stale` is whether the buttons should show the missing-FCS cue; `phase` is the blink phase (only
-- meaningful when stale). `phase` is derived purely from `now`, so when NOT stale the caller can fold a
-- constant term into the render dirty-gate signature -> zero extra repaints while the link is healthy.
function M.evaluate(now, s)
  s = s or {}
  local bootGrace = s.bootGraceMs or M.BOOT_GRACE_MS
  local dropGrace = s.dropGraceMs or M.DROP_GRACE_MS
  local half      = s.blinkHalfMs or M.BLINK_HALF_MS
  local stale
  if s.lastSeenMs == nil then
    -- No heartbeat has EVER arrived since boot -> quick startup recognition.
    stale = (now - (s.bootAt or now)) > bootGrace
  else
    -- Link was alive -> only cue after the (longer) drop grace, so lag/latency doesn't flicker it.
    stale = (now - s.lastSeenMs) > dropGrace
  end
  local phase = math.floor(now / half) % 2
  return stale, phase
end

return M
