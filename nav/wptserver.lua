-- nav/wptserver.lua
-- PURE NAV-side sync server seam for the waypoint/route store. Maps a request frame from the cockpit
-- NAV menu (the client) to an effect on the store + a reply frame. The transport -- wired channels
-- 108 req / 109 reply, protocol framing, persistence -- is wired in nav/app.lua; this module never
-- touches modems, fs, or peripherals, so it unit-tests headless.
--
-- apply(store, msg, rev) -> reply, newStore, newRev
--   msg.k == "wpt_get"                    -> {k="wpt_store", store, rev}                (read; rev kept)
--   msg.k == "wpt_op" {op, args}          -> dispatch to nav.waypoints CRUD; on success rev+1 and
--                                            reply {k="wpt_store", store, rev}; on failure keep rev
--                                            and reply {..., err}
--   anything else                         -> {k="wpt_err", err}                          (rev/store kept)
-- `rev` is a monotonic change counter the client uses to detect store changes (freshness). Disk ops
-- (wpt_disk) are handled by nav/wptdisk.lua and routed in from nav/app.lua (Task 1f), not here.
local W = require("nav.waypoints")

local M = {}

-- op name -> function(store, args) -> ok, err. Waypoint CRUD now; route ops added in Phase 2.
local OPS = {
  addWpt    = function(s, a) return W.addWpt(s, a) end,
  editWpt   = function(s, a) return W.editWpt(s, a and a.name, a and a.fields) end,
  deleteWpt = function(s, a) return W.deleteWpt(s, a and a.name) end,
}

local function storeReply(store, rev, err)
  return { k = "wpt_store", store = store, rev = rev, err = err }
end

function M.apply(store, msg, rev)
  rev = rev or 0
  msg = msg or {}
  if msg.k == "wpt_get" then
    return storeReply(store, rev), store, rev
  end
  if msg.k == "wpt_op" then
    local fn = OPS[msg.op]
    if not fn then
      return storeReply(store, rev, "unknown op: " .. tostring(msg.op)), store, rev
    end
    local ok, err = fn(store, msg.args)
    if not ok then
      return storeReply(store, rev, err or "op failed"), store, rev
    end
    return storeReply(store, rev + 1), store, rev + 1
  end
  return { k = "wpt_err", err = "unknown request: " .. tostring(msg.k) }, store, rev
end

return M
