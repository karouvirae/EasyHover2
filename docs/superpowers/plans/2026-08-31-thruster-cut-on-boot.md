# Thruster Cut-on-Boot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write `setPower(0)` on every on-network thruster at FCS process start (boot loader, flight launcher, flight runtime, hovertest) and again on clean exit, recovering last-command linger after reboot/unload.

**Architecture:** A tiny boot-safe `fcs.io.cut` module with injected peripheral accessors. Call it from the two FCS launchers and from `tools/flight.lua` / `tools/hover_test.lua`. Discovery is type-string contains `thruster`. No config, no control-loop I/O.

**Tech Stack:** Lua 5.1 / CC:Tweaked, CraftOS-PC headless (`tests/run_headless.sh` via Git Bash, not WSL).

**Spec:** `docs/superpowers/specs/2026-08-31-thruster-cut-on-boot-design.md`

## Global Constraints

- Lua 5.1, ASCII only in strings/comments (`--`, never unicode em-dash).
- TDD: failing test first, watch it fail, then minimal production code.
- No optimistic UI. No extra `getFuelAmountMb` / `getPower` / `peripheral.find` on the FCS **control path** (cut is process-start and clean-exit only).
- No new modem channels. Control loop stays the authority.
- Headless: Git Bash `bash tests/run_focus.sh` / `bash tests/run_headless.sh`. Bare `bash` is WSL and wrong. PowerShell: `bash tests/run_focus.sh` with `SUITES` env.
- After source that ships: `node tools/build.mjs` then Git Bash `bash tools/run_gen.sh`. Register new suites in BOTH `tests/run_headless.sh` and `tests/run_headless_dist.sh`.
- Commit per task. Branch `thruster-cut-on-boot` off current `main`. Work in the EasyHover2 clone (no extra worktree).
- Do not sleep to wait out Propulsion's 10-tick fade. Writing 0 starts it; that is enough.

---

### Task 1: `fcs.io.cut` module (discover + zero)

**Files:**
- Create: `fcs/io/cut.lua`
- Test: `tests/test_cut.lua`
- Modify: `tests/run_headless.sh` (add `"tests.test_cut"` to the `suites` table)
- Modify: `tests/run_headless_dist.sh` (add `"tests.test_cut"` to the `suites` table)

**Interfaces:**
- Consumes: injected `getNames`, `getType`, `wrap`, optional `dispatch`
- Produces:
  - `cut.isThrusterType(typ) -> bool`
  - `cut.names(getNames, getType) -> { name, ... }`
  - `cut.zero(wrap, names, dispatch) -> n` (attempted writes)
  - `cut.all(opts) -> n` where `opts` may supply the four functions; if `opts` is nil, use `_G.peripheral` when present else no-op

- [ ] **Step 1: Write the failing tests** in `tests/test_cut.lua`

```lua
local t = require("tests.framework")
local cut = require("fcs.io.cut")

t.test("isThrusterType: thruster type strings only", function()
  t.eq(cut.isThrusterType("thruster"), true)
  t.eq(cut.isThrusterType("vector_thruster"), true)
  t.eq(cut.isThrusterType("solid_fuel_thruster"), true)
  t.eq(cut.isThrusterType("ion_thruster"), true)
  t.eq(cut.isThrusterType("modem"), false)
  t.eq(cut.isThrusterType("monitor"), false)
  t.eq(cut.isThrusterType("altitude_sensor"), false)
  t.eq(cut.isThrusterType("redstone_relay"), false)
  t.eq(cut.isThrusterType(nil), false)
end)

t.test("names: keeps thruster types, drops everything else", function()
  local names = { "left", "modem_0", "thr_1", "baro", "relay" }
  local types = {
    left = "vector_thruster",
    modem_0 = "modem",
    thr_1 = "thruster",
    baro = "altitude_sensor",
    relay = "redstone_relay",
  }
  local got = cut.names(function() return names end, function(n) return types[n] end)
  t.eq(#got, 2)
  t.eq(got[1], "left")
  t.eq(got[2], "thr_1")
end)

t.test("zero: writes setPower(0) on each wrapped thruster", function()
  local power = {}
  local wrap = function(name)
    return { setPower = function(v) power[name] = v end }
  end
  local n = cut.zero(wrap, { "a", "b" })
  t.eq(n, 2)
  t.eq(power.a, 0)
  t.eq(power.b, 0)
end)

t.test("zero: falls back to setThrust(0) when setPower is absent", function()
  local thrust
  local wrap = function()
    return { setThrust = function(v) thrust = v end }
  end
  cut.zero(wrap, { "x" })
  t.eq(thrust, 0)
end)

t.test("zero: a throwing write does not skip the rest", function()
  local ok
  local wrap = function(name)
    if name == "bad" then
      return { setPower = function() error("nope") end }
    end
    return { setPower = function(v) ok = v end }
  end
  cut.zero(wrap, { "bad", "good" })
  t.eq(ok, 0)
end)

t.test("zero: n>1 uses injected dispatch", function()
  local seen = 0
  local dispatch = function(fns)
    seen = #fns
    for i = 1, #fns do fns[i]() end
  end
  local wrap = function()
    return { setPower = function() end }
  end
  cut.zero(wrap, { "a", "b", "c" }, dispatch)
  t.eq(seen, 3)
end)

t.test("all: no peripheral API is a no-op", function()
  local n = cut.all({ getNames = nil, getType = nil, wrap = nil })
  t.eq(n, 0)
end)

t.test("all: discovers via opts and zeros", function()
  local power = {}
  local n = cut.all({
    getNames = function() return { "t0", "m0" } end,
    getType = function(n) return n == "t0" and "thruster" or "modem" end,
    wrap = function(name)
      return { setPower = function(v) power[name] = v end }
    end,
  })
  t.eq(n, 1)
  t.eq(power.t0, 0)
  t.eq(power.m0, nil)
end)
```

- [ ] **Step 2: Run to confirm failure.** From EasyHover2, Git Bash:

```
SUITES=tests.test_cut bash tests/run_focus.sh
```

Expected: FAIL (module missing or functions missing), not a harness crash.

- [ ] **Step 3: Write `fcs/io/cut.lua`** -- minimal. ASCII comments only. Default dispatch: 0 fns no-op, 1 fn call it, else `parallel.waitForAll` if present else sequential. `zero` pcalls each write. Prefer `setPower(0)`; if that field is absent, `setThrust(0)`. Count attempted names that had a wrapper with at least one of those methods. `all` reads `opts or {}` then `_G.peripheral`.

- [ ] **Step 4: Re-run `SUITES=tests.test_cut bash tests/run_focus.sh`. PASS.** Add `"tests.test_cut"` to both headless suite tables (source + dist), next to the other `tests.test_*` entries (after `tests.test_loop_diag` is fine).

- [ ] **Step 5: Commit** `feat(fcs): cut module zeros every thruster peripheral`

---

### Task 2: Wire cut into FCS start and clean exit

**Files:**
- Modify: `launchers/fcs.lua` (cut immediately after `package.path`, before `loaderui`)
- Modify: `launchers/flight.lua` (cut immediately after `package.path`, before `tools.flight`)
- Modify: `tools/flight.lua` (cut immediately after `package.path`; also `safeShutdown`)
- Modify: `tools/hover_test.lua` (`run()` first action)
- Modify: `tests/test_cut.lua` (add wiring tests that read launcher / flight source)

**Interfaces:**
- Consumes: `require("fcs.io.cut").all()`
- Produces: every FCS-role entry that can command thrusters calls cut at start; `safeShutdown` and hovertest end still zero; hovertest also zeros before baseline

- [ ] **Step 1: Write the failing wiring tests** at the bottom of `tests/test_cut.lua`

```lua
local function readAll(path)
  local f = fs.open(path, "r")
  t.truthy(f, "missing " .. path)
  local body = f.readAll() or ""
  f.close()
  return body
end

local function firstPos(body, needle)
  local i = body:find(needle, 1, true)
  t.truthy(i, "expected to find " .. needle)
  return i
end

t.test("launchers/fcs.lua cuts before the boot loader", function()
  local body = readAll("/launchers/fcs.lua")
  local cutAt = firstPos(body, "fcs.io.cut")
  local bootAt = firstPos(body, "loaderui")
  t.truthy(cutAt < bootAt, "cut must run before loaderui")
end)

t.test("launchers/flight.lua cuts before tools.flight", function()
  local body = readAll("/launchers/flight.lua")
  local cutAt = firstPos(body, "fcs.io.cut")
  local flightAt = firstPos(body, "tools.flight")
  t.truthy(cutAt < flightAt, "cut must run before tools.flight")
end)

t.test("tools/flight.lua cuts at process start and in safeShutdown", function()
  local body = readAll("/tools/flight.lua")
  t.truthy(body:find("fcs.io.cut", 1, true), "flight runtime must require fcs.io.cut")
  local startAt = firstPos(body, "package.path")
  local cutAt = firstPos(body, "fcs.io.cut")
  local loadAt = body:find("loadConfig", 1, true) or body:find("Backend.new", 1, true)
  t.truthy(loadAt, "expected loadConfig or Backend.new")
  t.truthy(cutAt > startAt, "cut after package.path")
  t.truthy(cutAt < loadAt, "cut before config/backend construction")
  local shut = body:find("safeShutdown", 1, true)
  t.truthy(shut, "safeShutdown present")
  -- a second cut (or the same require) must appear at or after safeShutdown
  local after = body:find("fcs.io.cut", shut, true)
  t.truthy(after, "safeShutdown must also cut")
end)

t.test("tools/hover_test.lua run() cuts before baseline", function()
  local body = readAll("/tools/hover_test.lua")
  t.truthy(body:find("fcs.io.cut", 1, true), "hover_test must require fcs.io.cut")
  local runAt = firstPos(body, "local function run")
  local cutAt = body:find("fcs.io.cut", runAt, true) or body:find("cut.all", runAt, true)
  local baseAt = firstPos(body, "baseline(")
  t.truthy(cutAt, "run() must call cut")
  t.truthy(cutAt < baseAt, "cut before baseline")
end)
```

Wiring tests that look for `fcs.io.cut` after `safeShutdown` must still pass if the implementation calls `cut.all()` inside `safeShutdown` (the token `fcs.io.cut` may only appear once at the top require -- if so, assert `safeShutdown` contains `cut.all` instead):

Accept **either**:
- `body:find("cut.all", shut, true)` inside/after `safeShutdown`, **or**
- a second `fcs.io.cut` require there.

Prefer a module-level `local cut = require("fcs.io.cut")` near the top of `tools/flight.lua` plus `pcall(cut.all)` at start and in `safeShutdown`. Then the wiring test should use `cut.all` at both sites.

Adjust the tests in this task so they match that preferred shape:

```lua
t.test("tools/flight.lua cuts at process start and in safeShutdown", function()
  local body = readAll("/tools/flight.lua")
  local startAt = firstPos(body, "package.path")
  local firstCut = firstPos(body, "cut.all")
  local loadAt = body:find("loadConfig", 1, true) or body:find("Backend.new", 1, true)
  t.truthy(loadAt, "expected loadConfig or Backend.new")
  t.truthy(firstCut > startAt and firstCut < loadAt, "cut.all before config/backend")
  local shut = firstPos(body, "local function safeShutdown")
  local shutCut = body:find("cut.all", shut, true)
  t.truthy(shutCut, "safeShutdown calls cut.all")
end)
```

- [ ] **Step 2: Run `SUITES=tests.test_cut bash tests/run_focus.sh`. Expect FAIL on the new wiring tests only; Task 1 tests stay green.**

- [ ] **Step 3: Wire.** Every call is `pcall(function() cut.all() end)` or `pcall(cut.all)` so a missing peripheral never blocks.

`launchers/fcs.lua`:

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
pcall(function() require("fcs.io.cut").all() end)
local loaderui = require("fcs.boot.loaderui")
```

`launchers/flight.lua`:

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
pcall(function() require("fcs.io.cut").all() end)
require("tools.flight")
```

`tools/flight.lua`: after `package.path`, `local cut = require("fcs.io.cut")` then `pcall(cut.all)` before other work. Inside `safeShutdown`, after the existing backend zeros, `pcall(cut.all)`.

`tools/hover_test.lua`: `local cut = require("fcs.io.cut")` at module load (with the other requires). First line of `run()`: `pcall(cut.all)`. Keep `killThrusters` at the end.

- [ ] **Step 4: Re-run `SUITES=tests.test_cut bash tests/run_focus.sh`. PASS.**

- [ ] **Step 5: Commit** `fix(fcs): zero thrusters at boot, flight start, and clean exit`

---

### Task 3: Minify + both manifests

**Files:**
- Generated: `dist/` (do not hand-edit)
- Generated: `manifest.lua`, `manifest-dev.lua`

**Interfaces:**
- Consumes: source from Tasks 1-2
- Produces: minified channel and both manifests in sync

- [ ] **Step 1: `node tools/build.mjs`**

- [ ] **Step 2: Git Bash `bash tools/run_gen.sh` then `bash tools/run_gen.sh --check`**

- [ ] **Step 3: Git Bash `bash tests/run_headless.sh` and `bash tests/run_headless_dist.sh`.** Both green. e2e not required unless a suite file or installer path changed in a way that e2e asserts (it should not).

- [ ] **Step 4: Commit** `build: minify cut-on-boot and regen manifests`

---
