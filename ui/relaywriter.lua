-- ui/relaywriter.lua
-- The engine's physical relay-write edge, factored out of ui/basalt/app.lua so it can be tested.
--
-- ui/engine.lua owns ALL of the feed logic and the block/feed INVERSION; this layer is a dumb
-- passthrough that applies the given physical `signal` to the currently-configured relay side.
-- Its one added responsibility: when the configured side CHANGES, release the side we were last
-- driving (set it off) before driving the new one -- otherwise a redstone_relay latches the old
-- side at its last value forever, so re-picking the side in the UI leaves a stray HIGH behind that
-- keeps whatever was there asserted (the "wrong side still blocked the chute" gotcha).
--
-- getRelay() -> the wrapped relay peripheral, or nil when unbound.
-- getSide()  -> the configured side string. Both are read fresh on every write so a rebind/side
--               change is picked up without rebuilding the writer.
local M = {}

function M.make(getRelay, getSide)
  local lastSide = nil
  return function(signal)
    local relay = getRelay()
    if not relay then return false end
    local side = getSide()

    -- Release the abandoned side first, so it can't stay latched at its last value.
    if lastSide ~= nil and lastSide ~= side then
      pcall(relay.setOutput, lastSide, false)
    end

    local ok = pcall(relay.setOutput, side, signal)
    if ok then lastSide = side end
    return ok
  end
end

return M
