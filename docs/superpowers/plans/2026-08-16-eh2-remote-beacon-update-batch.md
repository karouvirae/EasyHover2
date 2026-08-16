# EH2 Remote Beacon Update + SuiteX Beacon-Updater Tool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a token-guarded, remotely-triggerable "update + reboot" to the beacon role, a shell tool that broadcasts it and reports acks, a manifest `tools` section + SuiteX Advanced-tab "Beacon updater" checkbox, and a horizontal-honest beacon self-check (the first real payload).

**Architecture:** A pure `beacon/update.lua` codec+gate is the seam. `beacon/app.lua` gains one modem-message branch that, on a token-valid command, acks then reinstalls via the classic Suite and reboots. `tools/beaconupdate.lua` (pure, injected) broadcasts the command and collects acks; `launchers/beaconupdate.lua` is its shell glue. The beacon self-check switches to `geometry.hdop`-based wording, matching the NAV. The manifest gains a `tools` section (min+dev) built by the same require-closure machinery as roles; SuiteX installs the tool when its Advanced-tab checkbox is ticked.

**Tech Stack:** Lua 5.1 (CC:Tweaked), Basalt 2.0 full (SuiteX only), CraftOS-PC headless harness, `tests/framework.lua`, `node tools/build.mjs` + `tools/run_gen.sh`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-16-eh2-remote-beacon-update-design.md` — every task's requirements implicitly include it.
- **No peripheral/Basalt/fs/os access at module LOAD** — all such work inside functions/closures; every module `require()`s clean headless.
- **Pure modules stay pure:** `beacon/update.lua`, `tools/beaconupdate.lua` core logic take injected deps (modem/now/token/sleep) — no real peripherals.
- **Fail-closed (both ends, confirmed):** a beacon acts only if the command `token` is valid (non-empty after trimming) AND equals its configured `updateToken` (also valid); a beacon with no/blank token ignores commands and never reboots. The updater tool refuses to broadcast without a valid token.
- **Wire format:** update/ack frames reuse `fcs.comms.protocol` encode/decode (same as `nav/comms/gpsproto`). Coexistence on ch 65000 verified: `gpsproto.decode` returns nil for a frame lacking numeric x/y/z (`nav/comms/gpsproto.lua:15-20`); the update codec returns nil for anything whose `k` isn't a known kind.
- **Config is sacred:** `updateToken` + coordinates live in `/eh2_beacon.tbl`; the Suite never overwrites protected config on reinstall.
- **FCS + NAV untouched** (except NAV/beacon share `nav/lib/geometry.lua`, already shipped — this batch only *reads* `geometry.hdop`/`dopQuality`, no geometry change).
- **Frame kinds:** `eh2_beacon_update` (command), `eh2_beacon_update_ack` (ack). **Channel default:** 65000. **Repo:** `https://raw.githubusercontent.com/maar-10/EasyHover2/main`.
- **Commit footer** on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- **Gates (Task 9):** `bash tests/run_headless.sh` + `bash tests/run_headless_dist.sh` + `bash tests/run_suite_e2e.sh`; manifest/dist IN SYNC via `node tools/build.mjs && bash tools/run_gen.sh`.

---

## File Structure

**Create:**
- `beacon/update.lua` — pure: frame kinds, `validToken`, `command`/`ack` builders, `encode`/`decode`, `accepts` gate.
- `tools/beaconupdate.lua` — pure/injected: broadcast command + collect acks over a timeout.
- `launchers/beaconupdate.lua` — shell entry: config (token/channel) + real modem, calls the tool, prints the report.

**Modify:**
- `beacon/config.lua` — add `updateToken` default.
- `beacon/runtime.lua` — add `R:selfQuality(now)` (HDOP at own position).
- `beacon/console.lua` — HDOP-honest `constellation` row; `[U] update token` action + `readToken`; token shown SET/unset.
- `beacon/app.lua` — modem update branch (ack → Suite reinstall → reboot); `[U]` handling; pass `selfQuality` into the console model.
- `tools/gen_manifest.lua` — `TOOLS` table + `manifest.tools.beaconupdate` in both channels.
- `easyhover2_suitex.lua` — Advanced-tab "Beacon updater" checkbox + install-when-ticked wiring.
- `tests/run_headless.sh` + `tests/run_headless_dist.sh` — add new `tests.test_*` modules.

**Test:**
- New: `tests/test_beacon_update.lua`, `tests/test_beaconupdate.lua`.
- Extend: `tests/test_beacon_config.lua`, `tests/test_beacon_runtime.lua`, `tests/test_beacon_console.lua`, `tests/test_suitex.lua`, and manifest coverage in `tests/test_suite.lua` (or a new `tests/test_manifest_tools.lua`).

---

## Task 1: `beacon/update.lua` — pure codec + token gate

**Files:**
- Create: `beacon/update.lua`
- Test: `tests/test_beacon_update.lua`
- Modify: `tests/run_headless.sh` (add `"tests.test_beacon_update"`)

**Interfaces:**
- Produces:
  - `M.CMD_KIND = "eh2_beacon_update"`, `M.ACK_KIND = "eh2_beacon_update_ack"`
  - `M.validToken(t) -> bool` — true iff `t` is a string non-empty after removing whitespace.
  - `M.command(token) -> { k=CMD_KIND, token=token }`
  - `M.ack(id) -> { k=ACK_KIND, id=id }`
  - `M.encode(frame) -> string` / `M.decode(str) -> frame|nil` (reuses `fcs.comms.protocol`; decode returns nil unless `k` is a known kind)
  - `M.accepts(frame, cfgToken) -> bool` — true iff `frame` is a CMD_KIND frame whose `token` is valid AND equals `cfgToken` AND `cfgToken` is valid.

- [ ] **Step 1: Add the test module to the source suite array**

In `tests/run_headless.sh`, append `"tests.test_beacon_update"` to the `local suites = { ... }` table.

- [ ] **Step 2: Write the failing test**

Create `tests/test_beacon_update.lua`:

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local U = require("beacon.update")
local gpsproto = require("nav.comms.gpsproto")

t.test("validToken rejects nil/non-string/blank, accepts real strings", function()
  t.eq(U.validToken(nil), false)
  t.eq(U.validToken(123), false)
  t.eq(U.validToken(""), false)
  t.eq(U.validToken("   "), false)
  t.eq(U.validToken("s3cret"), true)
end)

t.test("command/ack build the right shapes", function()
  t.eq(U.command("tok").k, U.CMD_KIND); t.eq(U.command("tok").token, "tok")
  t.eq(U.ack("beacon-7").k, U.ACK_KIND); t.eq(U.ack("beacon-7").id, "beacon-7")
end)

t.test("encode/decode round-trips a command and an ack", function()
  local c = U.decode(U.encode(U.command("tok")))
  t.truthy(c and c.k == U.CMD_KIND and c.token == "tok", "command survives")
  local a = U.decode(U.encode(U.ack("b1")))
  t.truthy(a and a.k == U.ACK_KIND and a.id == "b1", "ack survives")
end)

t.test("decode returns nil for a GPS frame and for garbage", function()
  t.eq(U.decode(gpsproto.encode({ id = "b1", x = 1, y = 2, z = 3 })), nil)
  t.eq(U.decode("not a frame"), nil)
end)

t.test("gpsproto.decode returns nil for an update frame (coexistence)", function()
  t.eq(gpsproto.decode(U.encode(U.command("tok"))), nil)
end)

t.test("accepts is the fail-closed gate", function()
  t.eq(U.accepts(U.command("tok"), "tok"), true, "valid match accepted")
  t.eq(U.accepts(U.command("tok"), "other"), false, "mismatch rejected")
  t.eq(U.accepts(U.command("tok"), ""), false, "blank config token rejected")
  t.eq(U.accepts(U.command(""), "tok"), false, "blank command token rejected")
  t.eq(U.accepts(U.ack("b1"), "tok"), false, "non-command rejected")
  t.eq(U.accepts(nil, "tok"), false, "nil frame rejected")
end)
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: SUITE LOAD FAILURE for `tests.test_beacon_update` (module `beacon.update` not found) — RED. Manifest check PASS (new file not yet in any role closure).

- [ ] **Step 4: Write the minimal implementation**

Create `beacon/update.lua`:

```lua
-- beacon/update.lua
-- PURE codec + fail-closed token gate for the remote beacon-update protocol. No peripherals/os/fs.
-- Rides the shared GPS channel (default 65000) using the SAME wire format as nav/comms/gpsproto
-- (fcs.comms.protocol), so a beacon/NAV that also hears GPS frames is never confused: gpsproto
-- rejects these (no numeric x/y/z) and this codec rejects GPS frames (wrong `k`).
local protocol = require("fcs.comms.protocol")

local M = {}
M.CMD_KIND = "eh2_beacon_update"
M.ACK_KIND = "eh2_beacon_update_ack"

--- A token is valid iff it is a non-empty string once whitespace is stripped.
function M.validToken(t)
  return type(t) == "string" and t:gsub("%s", "") ~= ""
end

function M.command(token) return { k = M.CMD_KIND, token = token } end
function M.ack(id) return { k = M.ACK_KIND, id = id } end

function M.encode(frame) return protocol.encode(frame) end

--- decode(str) -> frame | nil. Only returns frames of a known kind.
function M.decode(str)
  local f = protocol.decode(str)
  if type(f) ~= "table" then return nil end
  if f.k == M.CMD_KIND or f.k == M.ACK_KIND then return f end
  return nil
end

--- The single fail-closed gate: accept a command only when both tokens are valid and equal.
function M.accepts(frame, cfgToken)
  if type(frame) ~= "table" or frame.k ~= M.CMD_KIND then return false end
  if not M.validToken(cfgToken) then return false end
  if not M.validToken(frame.token) then return false end
  return frame.token == cfgToken
end

return M
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: `OK`. (If `protocol.encode` drops the `k`/`token` fields, check `fcs/comms/protocol.lua` — it serializes arbitrary tables; no filtering is expected. If it does filter, the update codec must serialize via `textutils.serialise` instead — but verify first.)

- [ ] **Step 6: Commit**

```bash
git add beacon/update.lua tests/test_beacon_update.lua tests/run_headless.sh
git commit -m "feat(beacon): remote-update codec + fail-closed token gate (TDD)"
```

---

## Task 2: `beacon/config.lua` — `updateToken`

**Files:**
- Modify: `beacon/config.lua:12-21` (the `defaults()` table)
- Test: `tests/test_beacon_config.lua` (extend — already in both suite arrays)

**Interfaces:**
- Produces: `defaults().updateToken == nil`; `withDefaults` preserves a saved token.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_beacon_config.lua`:

```lua
t.test("updateToken defaults to nil and a saved token is preserved", function()
  t.eq(Config.defaults().updateToken, nil, "no token by default (fail-closed)")
  t.eq(Config.withDefaults({ updateToken = "abc" }).updateToken, "abc", "saved token kept")
end)
```

(If the test file's require local isn't named `Config`, match the existing name at the top of the file.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: the new case FAILs — `withDefaults` drops `updateToken` because it isn't in `defaults()` (merge only carries keys present in defaults... plus saved-only keys are carried by the second loop, so this may actually PASS for the preserve case but the `defaults().updateToken == nil` is trivially true). To get a real RED, assert the field is *documented* in defaults: change the first assertion to `t.truthy(({Config.defaults()})[1] and true)` is not meaningful — instead assert presence explicitly:

Replace the test with:
```lua
t.test("updateToken is a declared default (nil) and a saved token is preserved", function()
  local d = Config.defaults()
  local hasKey = false
  for k in pairs(d) do if k == "updateToken" then hasKey = true end end
  t.truthy(hasKey, "updateToken is a declared config key")
  t.eq(Config.withDefaults({ updateToken = "abc" }).updateToken, "abc", "saved token kept")
end)
```
Now it FAILs on `hasKey` (the key isn't declared yet).

- [ ] **Step 3: Add the default**

In `beacon/config.lua`, inside `M.defaults()` return table, add after `enabled = true,`:

```lua
    updateToken = nil,      -- shared secret for remote update; unset = beacon ignores update commands
```

Note: a `nil` value in a Lua table literal does not create a key. To make the key *declared* (so `hasKey` passes and the intent is explicit), use the sentinel pattern the codebase already uses for unset coordinates is `nil` inside a nested table — but a top-level `nil` won't register. Instead declare it as `false` sentinel is wrong (breaks validToken). **Resolution:** keep `updateToken = nil` as documentation only, and change the test to assert behavior, not key presence:

Revert the Task-2 test to:
```lua
t.test("a saved updateToken is preserved through withDefaults; absent stays nil", function()
  t.eq(Config.withDefaults({ updateToken = "abc" }).updateToken, "abc", "saved token kept")
  t.eq(Config.withDefaults({}).updateToken, nil, "absent -> nil (fail-closed)")
end)
```
This is a real behavioral test: `withDefaults({updateToken="abc"})` must keep it (carried by merge's saved-only second loop — verify it does) and `withDefaults({})` yields nil. Add the `updateToken = nil` documentation line to `defaults()` regardless (it documents the field for readers).

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add beacon/config.lua tests/test_beacon_config.lua
git commit -m "feat(beacon): updateToken config field (fail-closed default) (TDD)"
```

---

## Task 3: `beacon/runtime.lua` — `R:selfQuality`

**Files:**
- Modify: `beacon/runtime.lua` (add module fn `M.selfQuality` + method `R:selfQuality`)
- Test: `tests/test_beacon_runtime.lua` (extend)

**Interfaces:**
- Consumes: `geometry.hdop`, `geometry.dopQuality` (already in `nav/lib/geometry.lua`).
- Produces: `M.selfQuality(selfPos, peers) -> { hosts, quality?, errorEst? }` — `hosts` = count of valid positions in `[self]+peers`; when `hosts >= 4` and HDOP is computable, also `quality` (0..1) and `errorEst` (blocks); else just `hosts`. `R:selfQuality(now)` calls it with `self.config.pos` and `self:peers(now)`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_beacon_runtime.lua` (match the file's existing `require` locals; it already requires the beacon runtime — reuse that local, and add `local geometry = require("nav.lib.geometry")` if needed):

```lua
t.test("selfQuality reports GOOD for a wide, flat mesh and POOR for a clustered one", function()
  local Runtime = require("beacon.runtime")
  -- self + 3 peers, spread wide but near build height (the in-game case)
  local selfPos = { x = 824, y = 86, z = 2922 }
  local peers = {
    ["68"] = { pos = { x = 6462,  y = 200, z = 6107  }, dist = 1 },
    ["69"] = { pos = { x = 7144,  y = 65,  z = -7266 }, dist = 1 },
    ["70"] = { pos = { x = -7210, y = 64,  z = -7260 }, dist = 1 },
  }
  local q = Runtime.selfQuality(selfPos, peers)
  t.eq(q.hosts, 4, "self + 3 peers")
  t.truthy(q.quality and q.quality >= 0.75, "wide-flat -> GOOD (" .. tostring(q.quality) .. ")")
  t.truthy(q.errorEst and q.errorEst < 2, "small horizontal error")

  local clustered = {
    ["68"] = { pos = { x = 66, y = 95, z = 2654 }, dist = 1 },
    ["69"] = { pos = { x = 41, y = 98, z = 2741 }, dist = 1 },
    ["70"] = { pos = { x = 99, y = -45, z = 2768 }, dist = 1 },
  }
  local qc = Runtime.selfQuality({ x = -34, y = 89, z = 2753 }, clustered)
  t.truthy(qc.quality and qc.quality < 0.5, "clustered -> POOR (" .. tostring(qc.quality) .. ")")
end)

t.test("selfQuality with fewer than 4 hosts reports hosts only", function()
  local Runtime = require("beacon.runtime")
  local q = Runtime.selfQuality({ x = 0, y = 0, z = 0 }, { ["a"] = { pos = { x = 10, y = 0, z = 0 }, dist = 1 } })
  t.eq(q.hosts, 2)
  t.eq(q.quality, nil, "no quality below 4 hosts")
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `Runtime.selfQuality` is nil (attempt to call a nil value).

- [ ] **Step 3: Write the implementation**

In `beacon/runtime.lua`, after `M.constellation` (around line 64), add:

```lua
--- selfQuality(selfPos, peers) -> { hosts, quality?, errorEst? }. HORIZONTAL fix quality this
--- beacon would give NAV, graded at its OWN position over [self + heard peers] -- the honest,
--- HDOP-based metric (matches nav/runtime + nav/ui/main). < 4 hosts -> hosts only (no quality).
function M.selfQuality(selfPos, peers)
  local list = {}
  if validPos(selfPos) then list[#list + 1] = { x = selfPos.x, y = selfPos.y, z = selfPos.z } end
  local ids = {}
  for id in pairs(peers or {}) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  for _, id in ipairs(ids) do
    local p = peers[id]
    if validPos(p.pos) then list[#list + 1] = { x = p.pos.x, y = p.pos.y, z = p.pos.z } end
  end
  local hosts = #list
  if hosts < geometry.REQUIRED_HOSTS or not validPos(selfPos) then return { hosts = hosts } end
  local dq = geometry.dopQuality(geometry.hdop(list, selfPos))
  return { hosts = hosts, quality = dq.quality, errorEst = dq.errorEst }
end
```

And add the method near the other `R:` methods (after `R:constellation`, ~line 119):

```lua
function R:selfQuality(now)
  return M.selfQuality(self.config.pos, self:peers(now))
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add beacon/runtime.lua tests/test_beacon_runtime.lua
git commit -m "feat(beacon): HDOP-honest selfQuality at own position (TDD)"
```

---

## Task 4: `beacon/console.lua` — honest constellation row + `[U]` token action

**Files:**
- Modify: `beacon/console.lua`
- Test: `tests/test_beacon_console.lua` (extend)

**Interfaces:**
- Consumes: `model.selfQuality` (from Task 3), `cfg.updateToken`.
- Produces:
  - `Console.ACTIONS.u = "setToken"`; footer shows `[U] update token: SET|unset`.
  - `Console.readToken(reader) -> string|nil` — reads a line, trims; returns nil for blank (keep/cancel).
  - The constellation row renders `GOOD|FAIR|POOR  ~<e> blk` from `model.selfQuality` (thresholds: GOOD ≥ 0.75, FAIR ≥ 0.4, else POOR), or `<n> of 4  waiting` when `hosts < 4`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_beacon_console.lua` (reuse the existing `Console` local):

```lua
t.test("[U] maps to setToken and the footer shows SET/unset", function()
  t.eq(Console.actionFor("u"), "setToken")
  local rowsUnset = Console.render({ id = "b1", updateToken = nil }, {}, 51)
  local rowsSet   = Console.render({ id = "b1", updateToken = "s" }, {}, 51)
  local function footerHas(rows, needle)
    for _, e in ipairs(rows.footer or {}) do if e.text:find(needle, 1, true) then return true end end
    return false
  end
  t.truthy(footerHas(rowsUnset, "update token: unset"), "unset shown")
  t.truthy(footerHas(rowsSet, "update token: SET"), "SET shown, never the value")
  t.truthy(not footerHas(rowsSet, "s"), "token value never echoed") -- 's' would only match the value
end)

t.test("constellation row is HDOP-honest (GOOD/POOR/waiting), not USABLE/coplanar", function()
  local function conRow(rows)
    for _, e in ipairs(rows) do if e.text:find("constellation", 1, true) then return e.text end end
  end
  local good = conRow(Console.render({ id = "b1", pos = { x=0,y=0,z=0 } },
    { selfQuality = { hosts = 4, quality = 1.0, errorEst = 0.7 } }, 51))
  t.truthy(good:find("GOOD", 1, true) and good:find("blk", 1, true), "GOOD ~N blk: " .. tostring(good))
  local poor = conRow(Console.render({ id = "b1", pos = { x=0,y=0,z=0 } },
    { selfQuality = { hosts = 4, quality = 0.1, errorEst = 9 } }, 51))
  t.truthy(poor:find("POOR", 1, true), "POOR: " .. tostring(poor))
  local wait = conRow(Console.render({ id = "b1", pos = { x=0,y=0,z=0 } },
    { selfQuality = { hosts = 2 } }, 51))
  t.truthy(wait:find("waiting", 1, true), "waiting: " .. tostring(wait))
end)

t.test("readToken trims and treats blank as nil", function()
  t.eq(Console.readToken(function() return "  hey  " end), "hey")
  t.eq(Console.readToken(function() return "   " end), nil)
end)
```

(The `not footerHas(rowsSet, "s")` guard is brittle if "SET" contains no lowercase s — it doesn't; `"SET"` is uppercase, and "update token: SET" has no standalone value — good. If the label wording changes, adjust.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `actionFor("u")` is nil, `readToken` missing, constellation still renders USABLE.

- [ ] **Step 3: Implement**

In `beacon/console.lua`:

1. Add `u = "setToken"` to `Console.ACTIONS` (line 13):
```lua
Console.ACTIONS = { p = "setPosition", e = "toggleEnabled", v = "verify", u = "setToken", q = "quit" }
```

2. Replace the constellation block (lines ~77-83) with the HDOP-honest version:
```lua
  -- the constellation, graded HONESTLY on HORIZONTAL geometry (matches the NAV): a wide, flat
  -- spread is GOOD even though it is "coplanar" -- only horizontal dilution matters for nav.
  local sq = model.selfQuality or { hosts = 0 }
  if (sq.hosts or 0) < 4 then
    row(("constellation  %d of 4   waiting"):format(sq.hosts or 0), "dim")
  else
    local q = sq.quality or 0
    local label = (q >= 0.75 and "GOOD") or (q >= 0.4 and "FAIR") or "POOR"
    local err = sq.errorEst and ("  ~%d blk"):format(math.floor(sq.errorEst + 0.5)) or ""
    row(("constellation  %d of 4   %s%s"):format(sq.hosts, label, err),
      (q >= 0.75 and "good") or (q >= 0.4 and "normal") or "bad")
  end
```

3. Add the `[U]` footer entry in the `rows.footer` list (after `[V]`):
```lua
    { text = ("[U] update token: %s"):format(cfg.updateToken and "SET" or "unset"),
      tone = cfg.updateToken and "good" or "dim" },
```

4. Add `readToken` near `readPosition`:
```lua
--- Read one line as the shared update secret. Injected reader (production passes `read`). Blank
--- (after trimming) returns nil = keep/cancel; the caller never echoes the value back to screen.
function Console.readToken(reader)
  local text = tostring(reader() or ""):gsub("%s", "")
  if text == "" then return nil end
  return text
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: `OK`. If any pre-existing beacon-console test asserted the old `USABLE/UNUSABLE`/`constellation` wording, update it to the new honest wording (it was testing the behavior we intentionally changed).

- [ ] **Step 5: Commit**

```bash
git add beacon/console.lua tests/test_beacon_console.lua
git commit -m "feat(beacon): HDOP-honest constellation row + [U] update-token entry (TDD)"
```

---

## Task 5: `beacon/app.lua` — update branch + `[U]` handling + selfQuality wiring

**Files:**
- Modify: `beacon/app.lua`

**Interfaces:**
- Consumes: `beacon.update` (Task 1), `rt:selfQuality` (Task 3), `Console.readToken`/`setToken` (Task 4).
- Produces: on a token-valid `modem_message` command → ack on `cfg.channel` → Suite reinstall via `wget run` → `os.reboot()` on success; `[U]` saves the token; the console model includes `selfQuality`.

> This file is thin peripheral/event glue (it has no test file, by the project's convention — all decisions are tested in `beacon.update`/`beacon.runtime`/`beacon.console`). Keep new logic delegated to those modules; only wiring lives here.

- [ ] **Step 1: Add the requires + constant**

At the top of `beacon/app.lua`, add to the requires:
```lua
local Update = require("beacon.update")
```
And a repo constant near the top of the file (mirrors `ui/basalt/app.lua`'s `REPO` — documented duplication so this glue needs no cross-require of the Suite):
```lua
local SUITE_URL = "https://raw.githubusercontent.com/maar-10/EasyHover2/main/easyhover2_suite.lua"
```

- [ ] **Step 2: Include selfQuality in the console model**

In `M.run`'s `repaint()`, extend the `model` table:
```lua
    local model = {
      selfCheck = rt:selfCheck(), constellation = rt:constellation(),
      selfQuality = rt:selfQuality(),
      peers = rt:peers(), seq = rt.seq,
    }
```

- [ ] **Step 3: Handle the update command in the modem branch**

Replace the `modem_message` branch:
```lua
    elseif name == "modem_message" then
      -- side, channel, replyChannel, message, distance
      rt:onModemMessage(ev[3], ev[4], ev[5], ev[6])
```
with:
```lua
    elseif name == "modem_message" then
      -- side, channel, replyChannel, message, distance
      rt:onModemMessage(ev[3], ev[4], ev[5], ev[6])
      -- Remote update: a token-valid command -> ack, reinstall via the Suite, reboot. Fail-closed:
      -- Update.accepts() rejects a blank/mismatched token, so an unprovisioned beacon never reboots.
      local frame = Update.decode(ev[5])
      if frame and modem and Update.accepts(frame, cfg.updateToken) then
        modem.transmit(cfg.channel, cfg.channel, Update.encode(Update.ack(cfg.id)))
        term.setCursorPos(1, 1); term.clear()
        print("remote update received -- reinstalling + rebooting...")
        local ok = pcall(function() return shell.run("wget", "run", SUITE_URL) end)
        if ok then os.reboot() else print("update failed; staying on current version"); os.sleep(2); repaint() end
      end
```

- [ ] **Step 4: Handle `[U]` in the char branch**

In the `char` action handling, add a branch alongside the others:
```lua
      elseif action == "setToken" then
        term.clear(); term.setCursorPos(1, 1)
        term.write("Shared update secret (blank = keep): ")
        local tok = Console.readToken(read)
        if tok then cfg.updateToken = tok; save() end
        repaint()
```

- [ ] **Step 5: Verify the whole suite still passes**

Run: `bash tests/run_headless.sh`
Expected: `OK` (no new test; existing tests unaffected — this is glue). Confirms the app module still loads clean headless (no load-time side effects introduced).

- [ ] **Step 6: Commit**

```bash
git add beacon/app.lua
git commit -m "feat(beacon): app wiring -- remote update branch, [U] token, selfQuality model"
```

---

## Task 6: `tools/beaconupdate.lua` + `launchers/beaconupdate.lua` — the updater

**Files:**
- Create: `tools/beaconupdate.lua`, `launchers/beaconupdate.lua`
- Test: `tests/test_beaconupdate.lua`
- Modify: `tests/run_headless.sh` (add `"tests.test_beaconupdate"`)

**Interfaces:**
- Consumes: `beacon.update` (Task 1).
- Produces:
  - `tools.beaconupdate.M.run(deps) -> { ok, responders?, err? }` where `deps = { token, channel, transmit(ch,reply,msg), pull(timeoutS)->id|nil, timeoutS }`. Refuses (`ok=false, err`) if `token` invalid; else broadcasts one command frame and collects ack ids until no ack arrives within `timeoutS` (or a max window), returning sorted unique `responders`.
  - `launchers/beaconupdate.lua` — shell glue (real modem + config + prints).

- [ ] **Step 1: Add the test module to the source suite array**

In `tests/run_headless.sh`, append `"tests.test_beaconupdate"`.

- [ ] **Step 2: Write the failing test**

Create `tests/test_beaconupdate.lua`:

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Tool = require("tools.beaconupdate")
local U = require("beacon.update")

t.test("refuses to broadcast without a valid token", function()
  local sent = {}
  local r = Tool.run({ token = "  ", channel = 65000,
    transmit = function(...) sent[#sent+1] = { ... } end, pull = function() return nil end })
  t.eq(r.ok, false, "refused"); t.eq(#sent, 0, "nothing broadcast")
end)

t.test("broadcasts exactly one command frame carrying the token", function()
  local sent = {}
  Tool.run({ token = "tok", channel = 65000,
    transmit = function(ch, reply, msg) sent[#sent+1] = { ch = ch, msg = msg } end,
    pull = function() return nil end })
  t.eq(#sent, 1, "one broadcast")
  t.eq(sent[1].ch, 65000)
  local f = U.decode(sent[1].msg)
  t.truthy(f and f.k == U.CMD_KIND and f.token == "tok", "carries the command + token")
end)

t.test("collects and sorts ack ids, ignoring non-acks and dupes", function()
  local acks = { "beacon-70", "beacon-67", "beacon-70", nil }  -- nil ends the window
  local i = 0
  local r = Tool.run({ token = "tok", channel = 65000,
    transmit = function() end,
    pull = function()
      i = i + 1
      local id = acks[i]
      if id == nil then return nil end
      return id
    end })
  t.eq(r.ok, true)
  t.eq(table.concat(r.responders, ","), "beacon-67,beacon-70", "sorted + de-duped")
end)
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: SUITE LOAD FAILURE for `tests.test_beaconupdate` (module missing) — RED.

- [ ] **Step 4: Implement the tool**

Create `tools/beaconupdate.lua`:

```lua
-- tools/beaconupdate.lua
-- PURE/injected core of the beacon updater: broadcast one token-guarded update command and collect
-- the acks beacons send just before they reboot. No real peripherals -- deps.transmit / deps.pull
-- are injected (launchers/beaconupdate.lua wires the real ender modem). Fail-closed: refuses to send
-- without a valid token.
local Update = require("beacon.update")

local M = {}
M.DEFAULT_TIMEOUT = 2.5   -- seconds to wait for acks after the broadcast

--- run(deps) -> { ok, responders?, err? }. deps: token, channel, transmit(ch,reply,msg),
--- pull(timeoutS)->ackId|nil (returns the next ack's beacon id, or nil when the window elapses),
--- timeoutS (optional).
function M.run(deps)
  deps = deps or {}
  if not Update.validToken(deps.token) then
    return { ok = false, err = "no valid update token set -- refusing to broadcast" }
  end
  local timeoutS = deps.timeoutS or M.DEFAULT_TIMEOUT
  deps.transmit(deps.channel, deps.channel, Update.encode(Update.command(deps.token)))

  local seen, order = {}, {}
  while true do
    local id = deps.pull(timeoutS)
    if id == nil then break end
    if not seen[id] then seen[id] = true; order[#order + 1] = id end
  end
  table.sort(order, function(a, b) return tostring(a) < tostring(b) end)
  return { ok = true, responders = order }
end

return M
```

Create `launchers/beaconupdate.lua`:

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local Tool = require("tools.beaconupdate")
local Update = require("beacon.update")

local CFG_PATH = "/eh2_beacon_update.tbl"

local function loadCfg()
  if not fs.exists(CFG_PATH) or fs.isDir(CFG_PATH) then return {} end
  local f = fs.open(CFG_PATH, "r"); local raw = f.readAll(); f.close()
  local c = textutils.unserialise(raw or ""); return type(c) == "table" and c or {}
end

local function saveCfg(c)
  local f = fs.open(CFG_PATH, "w"); f.write(textutils.serialise(c)); f.close()
end

local function findModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local m = peripheral.wrap(name)
      if m.isWireless and m.isWireless() then return m end
    end
  end
  return nil
end

local cfg = loadCfg()
cfg.channel = cfg.channel or 65000
if not Update.validToken(cfg.updateToken) then
  write("Set the shared update secret (must match the beacons): ")
  local tok = read()
  tok = tostring(tok or ""):gsub("%s", "")
  if tok == "" then print("no token entered -- aborting."); return end
  cfg.updateToken = tok; saveCfg(cfg)
end

local modem = findModem()
if not modem then print("no wireless/ender modem found."); return end
modem.open(cfg.channel)

local deadline
local r = Tool.run({
  token = cfg.updateToken, channel = cfg.channel,
  transmit = function(ch, reply, msg) modem.transmit(ch, reply, msg) end,
  pull = function(timeoutS)
    if deadline == nil then deadline = os.clock() + timeoutS end
    while true do
      local remaining = deadline - os.clock()
      if remaining <= 0 then return nil end
      local timer = os.startTimer(remaining)
      local ev = { os.pullEvent() }
      if ev[1] == "modem_message" then
        local f = Update.decode(ev[5])
        if f and f.k == Update.ACK_KIND then return f.id end
      elseif ev[1] == "timer" and ev[2] == timer then
        return nil
      end
    end
  end,
})

if not r.ok then print(r.err); return end
if #r.responders == 0 then
  print("no beacons answered (asleep/unloaded, or wrong token/channel).")
else
  print("updating: " .. table.concat(r.responders, ", "))
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: `OK`. (Only `tools/beaconupdate.lua` is unit-tested; the launcher is thin real-peripheral glue.)

- [ ] **Step 6: Commit**

```bash
git add tools/beaconupdate.lua launchers/beaconupdate.lua tests/test_beaconupdate.lua tests/run_headless.sh
git commit -m "feat(tools): beacon updater -- broadcast update + collect/report acks (TDD)"
```

---

## Task 7: `tools/gen_manifest.lua` — a `tools` section

**Files:**
- Modify: `tools/gen_manifest.lua`
- Test: create `tests/test_manifest_tools.lua`; Modify `tests/run_headless.sh` (add `"tests.test_manifest_tools"`)

**Interfaces:**
- Produces: `manifest.tools.beaconupdate = { entry = "beaconupdate", files = { {dst,size,sum,src}, ... }, title = ... }` in BOTH `manifest.lua` (min) and `manifest-dev.lua` (dev), built from the require-closure of `launchers/beaconupdate.lua` (same machinery as roles).

> **Read `tools/gen_manifest.lua` fully first.** Mirror the existing `ROLES` → `buildRole` path for a new `TOOLS` table → `buildTool`. A tool is simpler than a role: no `configModule`, no `sharedDiag`, no `extraFiles`; its files are the closure of its launcher(s) with `dst = src` and the launcher itself shipped at its command name (`beaconupdate`). Include the result under `manifest.tools`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_manifest_tools.lua`:

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")

-- Read the generated manifest from disk (both channels are committed to the repo root, copied into
-- the headless data dir by run_headless.sh).
local function readManifest(path)
  local f = fs.open(path, "r"); local raw = f.readAll(); f.close()
  return textutils.unserialise(raw)
end

t.test("both manifests carry a beaconupdate tool with a non-empty file closure", function()
  for _, path in ipairs({ "/manifest.lua", "/manifest-dev.lua" }) do
    local m = readManifest(path)
    t.truthy(type(m.tools) == "table", path .. ": has a tools section")
    local tool = m.tools and m.tools.beaconupdate
    t.truthy(type(tool) == "table", path .. ": has beaconupdate")
    t.eq(tool.entry, "beaconupdate", path .. ": entry")
    t.truthy(tool.files and #tool.files > 0, path .. ": non-empty closure")
    -- the launcher ships at its command name
    local hasEntry = false
    for _, e in ipairs(tool.files) do if e.dst == "beaconupdate" then hasEntry = true end end
    t.truthy(hasEntry, path .. ": ships the launcher at 'beaconupdate'")
  end
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `m.tools` is nil (manifest has no tools section yet). NOTE: this will also make the manifest sync check pass/fail independently; if the sync check blocks the run, temporarily this test fails on the assertion, which is the RED we want. (If the manifest sync guard errors first, proceed to Step 3 — implementing the generator — then regenerate in Step 4.)

- [ ] **Step 3: Implement the `TOOLS` section**

In `tools/gen_manifest.lua`, following the `ROLES`/`buildRole` pattern (read the file to match its exact helpers — `launcherEntries`, `buildRole`, the min/dev channel handling):

1. Add a `TOOLS` table near `ROLES`:
```lua
local TOOLS = {
  beaconupdate = {
    title = "Beacon updater",
    entry = "beaconupdate",
    roots = { "launchers/beaconupdate.lua" },
  },
}
```

2. Add a `buildTool(name, spec, channel)` mirroring `buildRole` but simplified: resolve the closure of `spec.roots` (via `closure.resolve` + `MINIFY_PREFIXES` for the channel), ship the launcher root at `dst = spec.entry` and every other closure file at `dst = src`, compute size/sum per file, sort by dst, and return `{ title, entry, files, digest }`.

3. Where the manifest table is assembled for each channel, add:
```lua
  manifest.tools = {}
  for name, spec in pairs(TOOLS) do
    local tool, err = buildTool(name, spec, channel)
    if not tool then return nil, err end
    manifest.tools[name] = tool
  end
```
   (Place `manifest.tools` into BOTH the min and dev manifest assembly, exactly where `manifest.roles` is set.)

- [ ] **Step 4: Regenerate + verify**

Run: `node tools/build.mjs && bash tools/run_gen.sh`
Then: `bash tools/run_gen.sh --check` → expect exit 0 (IN SYNC).
Then: `bash tests/run_headless.sh` → expect `OK`.

- [ ] **Step 5: Commit**

```bash
git add tools/gen_manifest.lua tests/test_manifest_tools.lua tests/run_headless.sh manifest.lua manifest-dev.lua
git commit -m "feat(manifest): tools section shipping the beacon updater (min+dev) (TDD)"
```

---

## Task 8: `easyhover2_suitex.lua` — Advanced-tab "Beacon updater" checkbox

**Files:**
- Modify: `easyhover2_suitex.lua`
- Test: `tests/test_suitex.lua` (extend)

**Interfaces:**
- Produces: a pure `Suite.toolInstallPlan(opts) -> { install = bool, channel = "min"|"dev" }` helper (opts: `toolChecked`, `devChecked`), and UI wiring: an Advanced-tab checkbox under the dev checkbox; on an install run, if checked, the tool's files for the chosen channel are fetched + written via the Suite's existing `writeRelease` path.

> **Read the relevant `easyhover2_suitex.lua` regions first** (the Advanced frame `frameAdv` build ~line 582-587 for the dev checkbox pattern; the install path that writes a role's files; how it reads the manifest for the current channel). Keep the file's style.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_suitex.lua` (reuse the file's `Suite`/module local):

```lua
t.test("toolInstallPlan: checkbox gates install, dev checkbox picks the channel", function()
  t.eq(Suite.toolInstallPlan({ toolChecked = false, devChecked = false }).install, false)
  local a = Suite.toolInstallPlan({ toolChecked = true, devChecked = false })
  t.eq(a.install, true); t.eq(a.channel, "min", "dev off -> minified tool")
  local b = Suite.toolInstallPlan({ toolChecked = true, devChecked = true })
  t.eq(b.install, true); t.eq(b.channel, "dev", "dev on -> non-minified tool")
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `Suite.toolInstallPlan` is nil.

- [ ] **Step 3: Implement the pure helper + UI wiring**

1. Add the pure helper near the other `Suite.*` pure functions in `easyhover2_suitex.lua`:
```lua
--- toolInstallPlan(opts) -> { install, channel }. The Advanced-tab "Beacon updater" checkbox gates
--- installing the tool; the dev checkbox picks the variant (off -> minified, on -> non-minified).
function Suite.toolInstallPlan(opts)
  opts = opts or {}
  return {
    install = opts.toolChecked == true,
    channel = opts.devChecked and "dev" or "min",
  }
end
```

2. In the Advanced frame build (near `ui.devCheck`, ~line 586-587), add below it:
```lua
  ui.toolLabel = ui.frameAdv:addLabel({ x = 2, y = 5, text = "Optional tools", foreground = pal.dim })
  ui.beaconUpdCheck = ui.frameAdv:addCheckBox({ x = 2, y = 6,
    checked = (ctx.installBeaconUpdater == true), text = " Beacon updater" })
  ui.beaconUpdCheck:onChange(function(_, checked) ctx.installBeaconUpdater = checked end)
```
   (Match the exact CheckBox API the dev checkbox uses in this file — property names, `onChange` vs `:observe`. Read `ui.devCheck`'s construction and copy its idiom.)

3. In the install action (where the role's files are written after the plan is confirmed), after the role install completes, add:
```lua
  local tp = Suite.toolInstallPlan({ toolChecked = ctx.installBeaconUpdater, devChecked = (ctx.channel == "dev") })
  if tp.install then
    local toolManifest = <the manifest for tp.channel>   -- reuse whatever the install path already loaded/fetches
    local tool = toolManifest.tools and toolManifest.tools.beaconupdate
    if tool then
      -- fetch + writeRelease each file, exactly like the role file install loop
      for _, entry in ipairs(tool.files) do <fetch base.."/"..entry.src, verify size/sum, writeRelease("/"..entry.dst, body)> end
    end
  end
```
   Use the SAME fetch+verify+write helpers the role install uses (do not hand-roll a second writer). If the currently-loaded manifest is the role's channel and differs from `tp.channel`, fetch the correct-channel manifest first (the dev checkbox already drives the channel for the whole install, so in practice `tp.channel` equals the install channel — assert/reuse that).

- [ ] **Step 4: Run the test + regen/gates locally**

Run: `bash tests/run_headless.sh` → expect `OK`.
(The UI wiring itself isn't unit-tested — SuiteX needs an advanced terminal; the pure `toolInstallPlan` + the manifest-tools generation (Task 7) carry the logic. Manual in-world verification happens at deploy.)

- [ ] **Step 5: Commit**

```bash
git add easyhover2_suitex.lua tests/test_suitex.lua
git commit -m "feat(suitex): Advanced-tab Beacon-updater checkbox (min/dev variant) (TDD)"
```

---

## Task 9: Dist build + full acceptance gates

**Files:**
- Modify: `tests/run_headless_dist.sh` (add the new `tests.test_*` modules)
- Build outputs: `dist/**`, `manifest.lua`, `manifest-dev.lua`

- [ ] **Step 1: Add the new test modules to the dist suite array**

In `tests/run_headless_dist.sh`, append to `local suites = { ... }`:
`"tests.test_beacon_update", "tests.test_beaconupdate", "tests.test_manifest_tools"`.
(The extended existing test files — beacon_config/runtime/console, suitex — are already in the array.)

- [ ] **Step 2: Build dist + regen manifests**

Run: `node tools/build.mjs && bash tools/run_gen.sh`

- [ ] **Step 3: Verify IN SYNC**

Run: `bash tools/run_gen.sh --check` → exit 0.

- [ ] **Step 4: Run all three gates**

```bash
bash tests/run_headless.sh        # source -> OK
bash tests/run_headless_dist.sh   # minified dist -> OK
bash tests/run_suite_e2e.sh       # e2e phases -> pass
```
Expected: `OK` from both headless suites (no SUITE LOAD FAILURES); e2e green. If e2e asserts a fixed role/tool inventory, update its expectation to include the new `beaconupdate` tool.

- [ ] **Step 5: Commit**

```bash
git add tests/run_headless_dist.sh dist manifest.lua manifest-dev.lua
git commit -m "build: minify beacon-update tool into dist + dist suite wiring; gates green"
```

---

## Post-implementation (batch ship)

- Whole-branch review (superpowers:requesting-code-review).
- ff-merge to `main` → `git push origin main`.
- **In-world first rollout (manual, one-time):** visit each of the 4 beacons, reinstall the beacon role (brings the update handler + honest self-check), set the shared token via `[U]`; install the Beacon updater tool on a convenient PC (SuiteX Advanced tab) and set its matching token. Thereafter: run `beaconupdate` from that PC's shell to patch all beacons remotely.

## Self-Review notes (author)

- **Spec coverage:** protocol/kinds ✓ (T1), token config ✓ (T2), fail-closed both ends ✓ (T1 accepts + T6 refuse), honest self-check ✓ (T3+T4), update+ack+reboot via Suite ✓ (T5), tool ✓ (T6), manifest tools ✓ (T7), SuiteX checkbox+variant ✓ (T8), coexistence on 65000 ✓ (T1 test). Bootstrapping caveat documented (post-impl).
- **Type consistency:** `beacon.update` kinds/`accepts` used identically in app (T5) + tool (T6); `selfQuality` shape `{hosts,quality?,errorEst?}` produced in T3, consumed in T4 + app model (T5); `toolInstallPlan` shape used in T8; `manifest.tools.beaconupdate.files[].dst/src/size/sum` produced in T7, consumed in T8.
- **Open risk flagged for the implementer:** Task 2's TDD RED is weak (config merge already carries saved-only keys) — the behavioral test given is the real one; don't chase a false RED. Task 7/8 touch large existing files — READ them before editing and reuse existing helpers (closure builder, fetch/writeRelease) rather than duplicating.
