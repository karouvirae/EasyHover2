-- Boots the FCS flight app with per-cycle instrumentation ON, skipping the boot loader's
-- "Enable FCS logging?" prompt (a diagnostics shortcut). Press P in-flight to write
-- /eh2_flight_log.csv + upload the rolling window to carbide. Identical to `fcs`/`flight` otherwise.
package.path = "/?.lua;/?/init.lua;" .. package.path
_G.EH2_FLIGHTLOG = true
require("tools.flight")
