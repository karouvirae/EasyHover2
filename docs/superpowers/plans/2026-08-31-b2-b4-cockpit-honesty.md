# B2/B4 Cockpit Honesty Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** FCS SYNC paints SERVER/LINK on open and after START/STOP; NAV WPT/RT/DTC go read-only and stop sending when the NAV PC is silent.

**Architecture:** Call the apply() that already exists on fcssync. Add `wptClient:refreshOnline`, gate mutate/diskOp, tick freshness on the 2 s poll and apply event-mode NAV on a true->false drop. Leave unassigned monitors dark.

**Tech Stack:** Lua 5.1 / CC:Tweaked, Basalt 2.0 full, CraftOS-PC headless (Git Bash).

**Spec:** `docs/superpowers/specs/2026-08-31-b2-b4-cockpit-honesty-design.md`

## Global Constraints

- Lua 5.1, ASCII only in strings/comments (`--`, never unicode em-dash).
- TDD: failing test first, watch it fail, then minimal production code.
- No optimistic UI. No extra `getFuelAmountMb` / `getPower` / `peripheral.find` on the FCS control path.
- No new modem channels. Control loop stays the authority.
- Headless: Git Bash `bash tests/run_focus.sh` / `bash tests/run_headless.sh`. Bare `bash` is WSL and wrong. PowerShell: `& "C:\Program Files\Git\bin\bash.exe"`.
- After source that ships: `node tools/build.mjs` then Git Bash `bash tools/run_gen.sh`. Register new suites in BOTH runners only if a new test file is added (these tasks extend existing files).
- Commit per task. Branch `b2-b4-cockpit-honesty` off current `main`. Work in the EasyHover2 clone (no extra worktree).
- B6 stays dark. Do not build frames for unassigned monitors.

---

### Task 1: B2 -- FCS SYNC apply on open and START/STOP

**Files:**
- Modify: `ui/basalt/bitconfig/fcssync.lua`
- Test: `tests/test_bitconfig_fcssync.lua`

**Interfaces:**
- Consumes: existing `M.apply` closure, `M._onButton`, `runtime.cfgserver:status`
- Produces: `M.build` returns after one `apply()`; START/STOP onClick calls `_onButton` then `apply()`

- [ ] **Step 1: Write the failing tests** in `tests/test_bitconfig_fcssync.lua`

```lua
t.test("M.build: paints SERVER/LINK on construct without the caller applying", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local runtime = {
    cfgserver = {
      start = function() end, stop = function() end,
      status = function() return { running = false, lastSeen = nil } end,
    },
    uiRev = 0,
  }
  local h = M.build(basalt, frame, runtime, Nav.new("bitconfig"))
  t.eq(h.elements.serverLbl:getText(), "SERVER: STOPPED")
  t.eq(h.elements.linkLbl:getText(), "LINK: STOPPED")
end)

t.test("START onClick applies after cfgserver:start", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local running = false
  local runtime = {
    cfgserver = {
      start = function() running = true end, stop = function() end,
      status = function() return { running = running, lastSeen = nil } end,
    },
    uiRev = 0,
  }
  local h = M.build(basalt, frame, runtime, Nav.new("bitconfig"))
  t.eq(h.elements.serverLbl:getText(), "SERVER: STOPPED")
  h.elements.ssRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(running, true)
  t.eq(h.elements.serverLbl:getText(), "SERVER: RUNNING")
  t.eq(h.elements.linkLbl:getText(), "LINK: WAITING FOR FCS")
end)
```

If `ssRow.buttons[1].onClick` is not the public name, use whatever `configkit.actionRow` already exposes (same object the existing fcssync tests use as `h.elements.ssRow.buttons[1]`). Do not invent a new test-only hook on production.

- [ ] **Step 2: Run** `$env:SUITES="tests.test_bitconfig_fcssync"; & "C:\Program Files\Git\bin\bash.exe" tests/run_focus.sh` -- FAIL on the new tests (labels still `--`).

- [ ] **Step 3: Implement** in `fcssync.lua`: after `apply` is defined, `apply()`. START/STOP onClick: `M._onButton(runtime, "start"|"stop", os.epoch("utc")); apply()`. Keep `_onButton` itself unchanged (tests already cover start/stop/uiRev).

- [ ] **Step 4: Re-run focus. PASS.** Existing apply() tests stay green.

- [ ] **Step 5: Commit** `fix(ui): FCS SYNC paints SERVER/LINK on open and START/STOP`

---

### Task 2: B4 -- WPT stale gate + NAV read-only + poll apply

**Files:**
- Modify: `ui/basalt/wptclient.lua`
- Modify: `ui/basalt/app.lua` (`tickWptFreshness` + 2 s poll)
- Modify: `ui/basalt/pages/nav.lua` (refresh + disable mutate/disk rows)
- Modify: `HANDOFF-feature-complete-sweep-2026-08-30.md` (B6 accepted)
- Test: `tests/test_wptclient.lua`, `tests/test_basalt_app.lua`, `tests/test_page_nav.lua`

**Interfaces:**
- Consumes: existing `C:stale(now, maxAge)`, `C:mutate`, `C:diskOp`, `C:request`, `M.applyEventTop`
- Produces:
  - `C:refreshOnline(now, maxAge) -> bool` (`online` after applying stale)
  - `mutate`/`diskOp` send only if `refreshOnline()` is true
  - `request` always sends, still calls `refreshOnline` first
  - `M.tickWptFreshness(runtime, frameRecs, now) -> n` applies nav on true->false only
  - NAV refresh disables HERE/MAN/EDIT/DEL and RT/DTC mutate/disk rows when not online

- [ ] **Step 1: Failing tests**

`tests/test_wptclient.lua`:

```lua
t.test("stale: no reply is stale; a fresh reply is not; past 6000 ms is", function()
  local c = Client.new({ now = function() return 10000 end })
  t.eq(c:stale(10000), true)
  c:onReply({ k = "wpt_store", store = { waypoints = {}, routes = {} }, rev = 1 }, 10000)
  t.eq(c:stale(10000), false)
  t.eq(c:stale(10000 + 6000), false)
  t.eq(c:stale(10000 + 6001), true)
end)

t.test("refreshOnline clears online when stale", function()
  local c = Client.new({ now = function() return 20000 end })
  c:onReply({ k = "wpt_store", store = { waypoints = {}, routes = {} }, rev = 1 }, 10000)
  t.eq(c.online, true)
  t.eq(c:refreshOnline(20000), false)
  t.eq(c.online, false)
end)

t.test("mutate and diskOp do not send when stale; request still does", function()
  local sent = {}
  local c = Client.new({
    now = function() return 20000 end,
    link = { send = function(_, f) sent[#sent + 1] = f end },
  })
  c:onReply({ k = "wpt_store", store = { waypoints = {}, routes = {} }, rev = 1 }, 10000)
  c:mutate("addWpt", { name = "X" })
  c:diskOp("export")
  t.eq(#sent, 0)
  c:request()
  t.eq(#sent, 1)
  t.eq(sent[1].k, "wpt_get")
end)
```

`tests/test_basalt_app.lua`:

```lua
t.test("tickWptFreshness applies nav only on a true-to-false drop", function()
  local runtime = newRuntime()
  runtime.wptClient.lastReplyAt = 0
  runtime.wptClient.online = true
  local applied = 0
  local recs = { a = { built = { nav = { handle = { apply = function() applied = applied + 1 end } } } } }
  local n = M.tickWptFreshness(runtime, recs, 10000)
  t.eq(runtime.wptClient.online, false)
  t.eq(n, 1)
  t.eq(applied, 1)
  t.eq(M.tickWptFreshness(runtime, recs, 11000), 0, "already false: no second apply")
end)
```

`tests/test_page_nav.lua` -- extend the existing Basalt NAV build probe (or add one with a stale wptClient): after build, HERE (wptedit action row index 1) is `disabled` when the client is stale. If the probe does not currently push wptedit, `region:push("wptedit")` then `handle.apply({})` and read `elements`. Inspect `ui/basalt/pages/nav.lua` for the exact element path (`actionRow.buttons[1].state`).

- [ ] **Step 2: Run the three suites. FAIL for the right reason.**

- [ ] **Step 3: Implement** as in the spec. `tickWptFreshness` lives next to `applyEventTop` in `app.lua`. The 2 s poll calls it then `request()`. NAV `refresh` functions call `client():refreshOnline()` and `actionRow.setState(i, live and "off" or "disabled")` for mutate/disk buttons. Tabs stay enabled.

- [ ] **Step 4: Re-run the three suites. PASS.**

- [ ] **Step 5:** In `HANDOFF-feature-complete-sweep-2026-08-30.md`, B6: change KEEP to accepted / not an issue (unassigned monitors stay dark by operator choice 2026-08-31). Do not change `buildFrames`.

- [ ] **Step 6: Commit** `fix(ui): WPT/RT/DTC go read-only when NAV is silent`

---

### Task 3: Minify + both manifests

**Files:** generated `dist/`, `manifest.lua`, `manifest-dev.lua`

- [ ] **Step 1:** `node tools/build.mjs`
- [ ] **Step 2:** Git Bash `bash tools/run_gen.sh` then `--check`
- [ ] **Step 3:** Git Bash `bash tests/run_headless.sh` and `bash tests/run_headless_dist.sh`. Both green.
- [ ] **Step 4: Commit** `build: minify B2/B4 cockpit honesty and regen manifests`

---
