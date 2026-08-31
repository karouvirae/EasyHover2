# EasyHover 2 -- F1 FCS sibling-task isolation

**Date:** 2026-08-31
**Status:** approved (user: fix sweep issues one by one, SDD, merge+push main, pause after each)
**Sweep:** FCS audit at `main` @ `fca80f3`. This slice is **F1 only**.

## Goal

A throw in the command, health, or fuel-save path must **not** unwind `parallel.waitForAny` and cut thrust. Ctrl-T (`Terminated`) must still unwind and run `safeShutdown`. A failed apply must not be remembered as handled (UI retry must still work).

## Why

`tools/flight.lua` runs control/input/telemetry/command/health/fuel/status under one `parallel.waitForAny`. CC:T `rom/apis/parallel.lua` `waitForAny`: any function that errors or returns kills the group; `safeShutdown` then zeros thrusters.

Telemetry already `pcall`s send and `fault.orReraise`s. Command and health do not. Proven throw: `handleCommand("fuel")` -> `saveFuel` -> `writeFile` indexes `f.write` when `fs.open` returns nil (disk full). In-flight fuel pick then drops the craft.

`Receiver:receive` currently sets `handled[key]` **before** `apply`. After isolation, that would ACK-drop a retried command that never ran. Apply first; mark handled only after apply returns; if apply throws, do not mark, do not return an ack (throw to the task's pcall).

## Rules

- TDD. ASCII only in Lua strings/comments.
- `Terminated` is never swallowed (`fcs.runtime.fault.orReraise`).
- No extra modem channels. Control loop stays the authority. No `getFuelAmountMb` / `getPower` / `peripheral.find` on the control path.
- Dist + both manifests after source that ships (`node tools/build.mjs` then `bash tools/run_gen.sh`). New test files must be registered in **both** headless runners. Extending an existing registered suite does not need a new entry.
- User ship path: green tests + full-batch review -> merge to `main` + push. No PRs.

## Out of scope

F2 (CRUISE throttle on disengage), F3 (`tryAssemble` one-split), F4 (nav nil heading), L1 Auto-COM, L2 compassSign backfill, L3 LATERAL/HEADING order. Fuel-save persist failure (false from `writeAtomic`) does not have to roll back the live `setFuelScale`; the craft must keep flying.

## Behavior

1. `fault.protect(fn)`: `pcall(fn)`; on success return `true`; on error `fault.orReraise(err)` and return `false, string` for non-Terminated.
2. `commandTask` and `healthTask` wrap their send/apply bodies with `fault.protect` (same shape as today's telemetry `pcall` + `orReraise`). `os.pullEvent` / `sleep` stay outside so the loop still yields.
3. `writeFile` in `tools/flight.lua` uses `fcs.io.fsx.writeAtomic("/" .. name, body)` (false on open-fail, no throw).
4. `Receiver:receive`: for a new `(sid,id)`, call `apply(cmd)` first; set `handled[key]=true` only after apply returns; then return the ack. Duplicates still ack without apply. Invalid frames still return nil. Apply throw: key unmarked, no ack returned (error propagates).
