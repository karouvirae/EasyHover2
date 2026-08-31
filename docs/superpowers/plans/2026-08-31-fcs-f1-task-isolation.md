# F1 FCS sibling-task isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A throw in command/health/fuel-save cannot `waitForAny` the FCS; `Terminated` still unwinds; a failed apply is not remembered as handled.

**Architecture:** Add `fault.protect` next to existing `orReraise`. Mark command ids handled only after `apply` returns. Persist fuel cal through `fsx.writeAtomic` (false, not a crash). Wire command and health tasks the same way telemetry already wraps send.

**Tech Stack:** CC:Tweaked Lua, CraftOS-PC headless (`bash tests/run_headless.sh` / `tests/run_focus.sh`), existing `tests.framework`.

**Spec:** `docs/superpowers/specs/2026-08-31-fcs-f1-task-isolation-design.md`

## Global Constraints

- TDD: failing test first, watch it fail, then minimal production code.
- ASCII only in Lua strings/comments.
- `Terminated` is never swallowed (`fcs.runtime.fault.orReraise`).
- No extra modem channels. Control loop stays the authority. No `getFuelAmountMb` / `getPower` / `peripheral.find` on the control path.
- Dist + both manifests after source that ships (`node tools/build.mjs` then `bash tools/run_gen.sh`). Extending an existing registered test file does not need a new runner entry.
- Do not implement F2/F3/F4/L1/L2/L3 in this plan.
- Fuel-save persist failure must not throw; live `setFuelScale` may stay applied.

## File structure

- Modify: `fcs/runtime/fault.lua` -- add `protect`
- Modify: `fcs/comms/command.lua` -- apply then mark handled
- Modify: `tools/flight.lua` -- `writeFile` via fsx; command/health `fault.protect`
- Modify: `tests/test_fault.lua`, `tests/test_command.lua`
- No new test files (already registered).

### Task 1: Receiver apply-then-mark

**Files:**
- Modify: `fcs/comms/command.lua` (`Receiver:receive`)
- Test: `tests/test_command.lua`

**Interfaces:**
- Consumes: existing `Receiver:receive(frame, apply)` contract (ack table or nil)
- Produces: apply runs before `handled[key]=true`; apply throw leaves key unmarked and does not return an ack

- [ ] **Step 1: Write the failing tests** (append to `tests/test_command.lua`)

```lua
t.test("receiver does not mark handled when apply throws; retry applies", function()
  local r = command.Receiver.new()
  local n = 0
  local apply = function()
    n = n + 1
    if n == 1 then error("disk") end
  end
  local frame = { k = "cmd", sid = "S", id = 1, cmd = { k = "fuel" } }
  local ok = pcall(function() r:receive(frame, apply) end)
  t.eq(ok, false, "first apply throws")
  t.eq(n, 1)
  local ack = r:receive(frame, apply)
  t.eq(n, 2, "retry applied because first throw was not remembered")
  t.eq(ack.k, "ack"); t.eq(ack.id, 1); t.eq(ack.sid, "S")
end)

t.test("receiver still dedups after a successful apply", function()
  local r = command.Receiver.new()
  local n = 0
  local apply = function() n = n + 1 end
  local frame = { k = "cmd", sid = "S", id = 9, cmd = { k = "engage" } }
  r:receive(frame, apply)
  r:receive(frame, apply)
  t.eq(n, 1)
end)
```

Keep existing tests (`applies once per id and always acks`, session dedup, etc.). They must stay green after the reorder.

- [ ] **Step 2: Run tests to verify RED**

Run: `bash tests/run_focus.sh tests/test_command.lua`

Expected: FAIL -- first test: retry does not apply (`n` stays 1) because `handled[key]` is set before `apply`.

- [ ] **Step 3: Minimal implementation**

In `Receiver:receive`, for a new key:

```lua
  if not self.handled[key] then
    apply(frame.cmd)
    self.handled[key] = true
  end
  return { k = "ack", sid = frame.sid, id = frame.id }
```

Do not pcall inside `receive`. Do not change Sender.

- [ ] **Step 4: Run tests to verify GREEN**

Run: `bash tests/run_focus.sh tests/test_command.lua`

Expected: PASS, including the two new tests and the old session/retry tests.

- [ ] **Step 5: Commit**

```
git add fcs/comms/command.lua tests/test_command.lua
git commit -m "fix(fcs): mark command handled only after apply succeeds"
```

### Task 2: protect + fuel write + command/health wrap

**Files:**
- Modify: `fcs/runtime/fault.lua`
- Modify: `tools/flight.lua` (`writeFile`, `commandTask`, `healthTask`; telemetry may switch to `fault.protect`)
- Test: `tests/test_fault.lua`

**Interfaces:**
- Consumes: `fault.orReraise` from Task 1's tree (unchanged)
- Produces: `fault.protect(fn) -> true | false, string`; `writeFile` never throws on open-fail

- [ ] **Step 1: Write the failing tests** (append to `tests/test_fault.lua`)

```lua
t.test("protect: success returns true and does not throw", function()
  local ran = false
  local ok, err = require("fcs.runtime.fault").protect(function() ran = true end)
  t.eq(ok, true)
  t.eq(err, nil)
  t.eq(ran, true)
end)

t.test("protect: non-Terminated error returns false, string, does not throw", function()
  local ok, err = require("fcs.runtime.fault").protect(function() error("disk") end)
  t.eq(ok, false)
  t.eq(type(err), "string")
  t.truthy(string.find(err, "disk", 1, true))
end)

t.test("protect: Terminated is re-raised", function()
  local ok, err = pcall(function()
    require("fcs.runtime.fault").protect(function() error("Terminated", 0) end)
  end)
  t.eq(ok, false)
  t.eq(err, "Terminated")
end)
```

`error("Terminated", 0)` so the pcall message is exactly `Terminated` (matches `orReraise`).

- [ ] **Step 2: Run tests to verify RED**

Run: `bash tests/run_focus.sh tests/test_fault.lua`

Expected: FAIL -- `protect` is nil.

- [ ] **Step 3: Minimal `fault.protect`**

In `fcs/runtime/fault.lua`:

```lua
function M.protect(fn)
  local ok, err = pcall(fn)
  if not ok then return false, M.orReraise(err) end
  return true
end
```

- [ ] **Step 4: GREEN for protect**

Run: `bash tests/run_focus.sh tests/test_fault.lua`

Expected: PASS.

- [ ] **Step 5: Wire `tools/flight.lua`**

Require `fcs.io.fsx` (already have `fault`).

Replace `writeFile` with:

```lua
local function writeFile(name, body)
  return fsx.writeAtomic("/" .. name, body)
end
```

`commandTask` -- keep `os.pullEvent("modem_message")` outside protect; wrap receive+send:

```lua
local function commandTask()
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    local frame_ = cmdLink:onMessage(ch, msg)
    if frame_ then
      fault.protect(function()
        local ack = recv:receive(frame_, function(cmd) flight:handleCommand(cmd) end)
        if ack then cmdLink:send(ack) end
      end)
    end
  end
end
```

`healthTask`:

```lua
local function healthTask()
  while true do
    local beat = hbTx:beat(os.epoch("utc") / 1000)
    if beat then
      fault.protect(function() hbLink:send(beat) end)
    end
    sleep(0.25)
  end
end
```

Telemetry may keep its existing `pcall` + `orReraise` or switch to `fault.protect` -- same behavior. Do not wrap `controlTask` (already has its own device-fault pcall). Do not wrap `os.pullEvent`.

- [ ] **Step 6: Run focused suites**

Run: `bash tests/run_focus.sh tests/test_fault.lua tests/test_command.lua tests/test_fsx.lua tests/test_flight.lua`

Expected: PASS.

- [ ] **Step 7: Commit**

```
git add fcs/runtime/fault.lua tools/flight.lua tests/test_fault.lua
git commit -m "fix(fcs): isolate command/health/fuel-save from waitForAny"
```
