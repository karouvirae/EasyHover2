# EasyHover 2 -- cut thrusters on FCS process start

**Date:** 2026-08-31
**Status:** approved (user: no redstone on this craft; gate causes 1, 3, 4 even if they are not the in-world trigger; Superpowers SDD; merge+push main)
**Context:** uncommanded thruster fire while FCS is off or in the boot loader. Sweep: Propulsion `ControlMode` / last `setPower`, CC:T wired-network attach, EH2 boot does not write zeros until flight tasks start.

## Goal

The moment an FCS-role program starts -- boot loader, `flight` launcher, hover test, or the flight runtime itself -- write `setPower(0)` on every thruster on the wired network, before any interactive prompt or control loop. Keep the existing clean-exit zero (`safeShutdown` / hovertest kill). Recover after a dirty unload on the next boot.

## What Lua can and cannot do

| Cause | In Lua? | Gate |
|---|---|---|
| 1. UI/NAV keep last `digitalInput` while FCS reboots (`ThrusterPeripheralBase` only zeros on **last** detach) | Yes | `setPower(0)` from the FCS computer takes `PERIPHERAL` and clears throttle even if UI/NAV stay attached |
| 3. Chunk unload / hard off skips `Terminated` and can skip detach-zero (`isRemoved` early-return) | Not during the kill | Same `setPower(0)` on the **next** FCS start. Cannot run Lua while the VM is gone |
| 4. Propulsion 10-tick fade (`STARTUP_DURATION_TICKS`) | Cannot disable | Writing 0 **starts** the fade immediately. ~0.5 s of leftover envelope remains; that is the mod |

## Breakage (accepted)

- `setPower(0)` enters `ControlMode.PERIPHERAL` and ignores neighbor redstone until last computer detaches. This craft has no thruster redstone. Do not add limp-home RS without revisiting this.
- Discovery is every peripheral whose **type string contains** `thruster` (covers `thruster`, `vector_thruster`, `solid_fuel_thruster`, `ion_thruster`, creative variants). One on-craft wired network; will not touch sensors/modems/relays.
- Cost: one concurrent `setPower` batch (~1 server tick) at process start. Not on the control path after that.
- Does not engage, does not change setpoints, does not skip GND-SAFE. Disarmed flight still writes zeros as today.
- Already-zero thrusters get another `setPower(0)` (cut has no write-on-change cache). Harmless.

## Design

New `fcs/io/cut.lua` (boot-safe: no config, no modem, no Basalt):

- `isThrusterType(typ)` -- true iff `typ` is a string containing `thruster`
- `names(getNames, getType)` -- list of peripheral names to cut
- `zero(wrap, names, dispatch)` -- concurrent `pcall` of `setPower(0)` when present, else `setThrust(0)` if that exists. One write per name. Default dispatch matches `fcs/actuate/level.lua` (single call inline; else `parallel.waitForAll`; else sequential)
- `all(opts)` -- `names` + `zero` using `opts` or `_G.peripheral`. Missing peripheral API => empty list, no error

Call sites (each wrapped in `pcall` so a cut failure never blocks boot/flight):

1. `launchers/fcs.lua` -- immediately after `package.path`, **before** `loaderui.run()`
2. `launchers/flight.lua` -- immediately after `package.path`, **before** `require("tools.flight")`
3. `tools/flight.lua` -- immediately after `package.path`, **before** config load / LOADING. `safeShutdown` also calls `cut.all()` after the existing backend zeros
4. `tools/hover_test.lua` `run()` -- first line inside `run()`, before baseline; keep existing end-of-run kill

Do **not** put `peripheral.find` / `getPower` on the control loop. Cut runs once at process start and once on clean exit.

## Tests

`tests/test_cut.lua`: injected getNames/getType/wrap/dispatch (no real peripherals). Register in **both** headless runners.

- type filter keeps `thruster` / `vector_thruster`, drops `modem` / `monitor` / `altitude_sensor` / `redstone_relay`
- `zero` writes `setPower(0)` and not some other level
- missing `setPower` but present `setThrust` writes `setThrust(0)`
- a throwing `setPower` does not abort the rest
- n>1 uses the injected dispatch (not a serial for-loop only)
- `all()` with no peripheral global is a no-op
- launcher files `launchers/fcs.lua` and `launchers/flight.lua` call `fcs.io.cut` before `loaderui` / `tools.flight`
- `tools/flight.lua` source contains `fcs.io.cut` before `loadConfig` / backend construction

## Out of scope

- Changing Propulsion Java fade / attach
- Isolating UI/NAV from the thruster modem network
- UI-side cut on FCS heartbeat loss
- Calibrate / probe (probe already zeros; calibrate is a deliberate pulse)
- Limp-home redstone
