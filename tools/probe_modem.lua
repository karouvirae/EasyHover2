-- tools/probe_modem.lua
-- Measures modem.transmit mainThread cost so telemetry cadence can be budgeted
-- against the control loop (thruster writes must always win). Run on the FCS PC.
local modem = peripheral.find("modem")
if not modem then print("no modem found"); return end
local CH = 42
modem.open(CH)
local payload = ("x"):rep(256)   -- ~ a serialized telemetry snapshot
local function timeN(n)
  local t0 = os.epoch("utc")
  for _ = 1, n do modem.transmit(CH, CH, payload) end
  return os.epoch("utc") - t0
end
for _, n in ipairs({1, 5, 10, 20}) do
  local elapsed = timeN(n)
  print(("%3d transmit(s): %d ms  (%.1f ms/call)"):format(n, elapsed, elapsed / n))
end
print("Compare to setPower ~50ms/call. If << 50ms, telemetry is cheap.")
