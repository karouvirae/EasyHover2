-- Boots the FCS flight app with per-cycle instrumentation ON (writes /eh2_flight_log.csv,
-- pastebins on Ctrl-T). Identical to `fcs`/`flight` otherwise. Use for diagnostics only.
package.path = "/?.lua;/?/init.lua;" .. package.path
_G.EH2_FLIGHTLOG = true
require("tools.flight")
