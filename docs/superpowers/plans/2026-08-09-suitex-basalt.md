# EasyHover 2 SuiteX (Basalt 2.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `easyhover2_suitex.lua`, a Basalt 2.0 front-end for the EH2 Suite that reuses the classic Suite's engine unchanged.

**Architecture:** SuiteX is ONE self-contained `wget run` file (mirroring the classic Suite): pure helpers on a `SuiteX` table, guarded run, `return SuiteX` for tests. At runtime it fetches/caches a vendored `release/basalt-full.lua` and loads the classic `easyhover2_suite.lua` with `EH2_SUITE_NO_RUN=true` to borrow its engine. The classic pure-CC Suite stays the dependency-free fallback and is changed only additively.

**Tech Stack:** CC:Tweaked Lua 5.1, Basalt 2.0 (full build), CraftOS-PC headless tests.

## Global Constraints

- Lua 5.1 / CC:Tweaked. Wrapped peripherals take NO self.
- Basalt: **`release/basalt-full.lua` only** (pinned commit per memory `feedback-basalt-full-build`). Never core/plain/1.7. In tests render ONE frame with `basalt.update("timer", -1)`, never `basalt.run()`.
- **Classic `easyhover2_suite.lua` behavior + terminal output stay identical** — every change to it is additive (new table fields, an opt-in sink that is nil in classic runs).
- SuiteX must stay a single self-contained file (runs via `wget run` before anything is installed): all SuiteX helpers inline + exposed on the `SuiteX` table; guarded `if not _G.EH2_SUITEX_NO_RUN then SuiteX.run() end`; `return SuiteX`.
- ASCII-only glyphs (memory `reference-cct-font-ascii`).
- After any shipped change: `bash tools/run_gen.sh` (regen manifest) then `bash tools/run_gen.sh --check` = IN SYNC, `bash tests/run_headless.sh` green, commit, push main.
- New test files MUST be added to the `suites` list in `tests/run_headless.sh`.

## File Structure

- **Create** `easyhover2_suitex.lua` — the entire SuiteX program (helpers + Basalt glue + bootstrap).
- **Create** `release/basalt-full.lua` — vendored pinned Basalt full build.
- **Create** `tests/test_suitex.lua` — headless tests for `SuiteX.*` pure helpers.
- **Modify** `easyhover2_suite.lua` — additive: expose `fetch`, `readFile`, `STATE_FILE`, `base`, `checkFile` on `Suite`; route `say()` through an optional `Suite.sink`.
- **Modify** `tools/gen_manifest.lua` — include `release/basalt-full.lua` in the manifest (size+sum) so SuiteX can verify its fetch.
- **Modify** `tests/run_headless.sh` — register `tests.test_suitex`.
- **Modify** `tests/test_suite.lua` — cover the new sink + exposed helpers.

---

### Task 1: Expose classic-Suite engine surface + output sink

**Files:**
- Modify: `easyhover2_suite.lua` (near `say()` ~line 88; near the file-locals `fetch`/`readFile`; the `STATE_FILE`/`REPO` constants; add exports before the run guard ~line 1549)
- Test: `tests/test_suite.lua`

**Interfaces:**
- Produces: `Suite.fetch(url)`, `Suite.readFile(path)`, `Suite.STATE_FILE` (string), `Suite.base` (REPO url string), `Suite.checkFile(entry, read)` → `"ok"|"missing"|"corrupt"`, and `Suite.sink` (nil by default; when set to `function(text, colour) end`, `say()` routes to it instead of printing).

- [ ] **Step 1: Write the failing test** (append to `tests/test_suite.lua`)

```lua
t.test("say routes through Suite.sink when set, else prints (classic behavior)", function()
  t.eq(Suite.sink, nil, "sink defaults to nil so classic output is unchanged")
  local seen = {}
  Suite.sink = function(text, c) seen[#seen+1] = text end
  Suite.emit("hello", colours.lime)          -- Suite.emit = the shared say() exposed for the test
  Suite.sink = nil
  t.eq(seen[1], "hello", "sink received the line")
end)

t.test("engine helpers are exposed for SuiteX reuse", function()
  t.eq(type(Suite.fetch), "function")
  t.eq(type(Suite.readFile), "function")
  t.eq(type(Suite.checkFile), "function")
  t.eq(type(Suite.STATE_FILE), "string")
  t.eq(type(Suite.base), "string")
end)

t.test("checkFile classifies a file against its manifest entry", function()
  local entry = { dst = "x", size = 3, sum = Suite.checksum("abc") }
  t.eq(Suite.checkFile(entry, function() return "abc" end), "ok")
  t.eq(Suite.checkFile(entry, function() return nil end), "missing")
  t.eq(Suite.checkFile(entry, function() return "abX" end), "corrupt")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `Suite.emit`/`Suite.fetch`/`Suite.checkFile` nil.

- [ ] **Step 3: Implement (additive)**

In `easyhover2_suite.lua`, change the base `say()` to consult an optional sink, and expose it:

```lua
-- was: local function say(text, c) colour(c or colours.white); print(text) end
local function say(text, c)
  if Suite.sink then Suite.sink(text, c); return end     -- SuiteX routes output into a Basalt log
  colour(c or colours.white); print(text)
end
Suite.emit = say                                          -- exposed so a front-end can reuse the same sink
```

Near the run guard (before `if not _G.EH2_SUITE_NO_RUN then`), add the reuse surface (the RHS names already exist as file-locals/constants in this file):

```lua
Suite.fetch = fetch
Suite.readFile = readFile
Suite.STATE_FILE = STATE_FILE
Suite.base = REPO
function Suite.checkFile(entry, read)
  local body = read(entry.dst)
  if body == nil then return "missing" end
  if #body ~= entry.size or Suite.checksum(body) ~= entry.sum then return "corrupt" end
  return "ok"
end
```

(If the constant is named other than `STATE_FILE`/`REPO`, use the actual local name — grep `local STATE_FILE`, `local REPO` first.)

- [ ] **Step 4: Run to verify pass**

Run: `bash tools/run_gen.sh && bash tests/run_headless.sh`
Expected: PASS, manifest IN SYNC (updater sum changes — that's fine).

- [ ] **Step 5: Commit**

```bash
git add easyhover2_suite.lua manifest.lua tests/test_suite.lua
git commit -m "feat(suite): additive engine exposure + output sink for SuiteX reuse"
```

---

### Task 2: Vendor Basalt + add it to the manifest

**Files:**
- Create: `release/basalt-full.lua` (the pinned full build)
- Modify: `tools/gen_manifest.lua` (add a `basalt` entry alongside `updater`)
- Test: `tests/test_suite.lua` (manifest shape) — optional; the `--check` guard is the real gate.

**Interfaces:**
- Produces: `manifest.basalt = { size = <n>, sum = <fnv1a> }`; the vendored file at the pinned URL `<base>/release/basalt-full.lua`.

- [ ] **Step 1: Fetch the pinned Basalt full build into the repo**

Use the pinned commit from memory `feedback-basalt-full-build`. Download `release/basalt-full.lua` at that commit into `release/basalt-full.lua`. Verify it is the FULL build (grep for full-only elements). Record the commit in a one-line header comment.

- [ ] **Step 2: Write the failing test** (append to `tests/test_suite.lua`, guarded like the other manifest tests)

```lua
t.test("manifest records the vendored basalt for SuiteX to verify", function()
  local manifest = dofile("/manifest.lua") or require("manifest")
  t.eq(type(manifest.basalt), "table")
  t.truthy(manifest.basalt.size and manifest.basalt.size > 0, "basalt size")
  t.eq(type(manifest.basalt.sum), "string")
end)
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash tools/run_gen.sh && bash tests/run_headless.sh`
Expected: FAIL — `manifest.basalt` nil (generator doesn't emit it yet).

- [ ] **Step 4: Teach the generator to include basalt**

In `tools/gen_manifest.lua`, after computing `updater`, read `release/basalt-full.lua` and emit a sibling `basalt = { size, sum }` in the manifest table (mirror the `updater` block, using `readNorm` + `fnv1a`; tolerate absence with size 0 like `updater` does).

- [ ] **Step 5: Run to verify pass**

Run: `bash tools/run_gen.sh && bash tools/run_gen.sh --check && bash tests/run_headless.sh`
Expected: IN SYNC, PASS.

- [ ] **Step 6: Commit**

```bash
git add release/basalt-full.lua tools/gen_manifest.lua manifest.lua tests/test_suite.lua
git commit -m "feat(suite): vendor pinned basalt-full + record it in the manifest"
```

---

### Task 3: SuiteX scaffold (guarded file + table + test harness)

**Files:**
- Create: `easyhover2_suitex.lua`
- Create: `tests/test_suitex.lua`
- Modify: `tests/run_headless.sh` (add `"tests.test_suitex"` to the `suites` list)

**Interfaces:**
- Produces: `SuiteX` table; `require`ing the file with `_G.EH2_SUITEX_NO_RUN = true` returns it without running the UI.

- [ ] **Step 1: Write the failing test** (`tests/test_suitex.lua`)

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
_G.EH2_SUITEX_NO_RUN = true
local SuiteX = require("easyhover2_suitex")

t.test("suitex loads as a library without running the UI", function()
  t.eq(type(SuiteX), "table")
end)
```

- [ ] **Step 2: Register the suite** — add `"tests.test_suitex"` to the `suites` table in `tests/run_headless.sh`. Run: `bash tests/run_headless.sh`. Expected: FAIL — module `easyhover2_suitex` not found.

- [ ] **Step 3: Create the scaffold** (`easyhover2_suitex.lua`)

```lua
-- EasyHover 2 SuiteX -- Basalt 2.0 front-end for the Suite. Run via `wget run`.
-- Self-contained (helpers inline + on the SuiteX table) so it works before anything is installed;
-- fetches a vendored basalt-full.lua and the classic Suite (as a library) at runtime.
local SuiteX = {}

-- (helpers added in later tasks)

function SuiteX.run()
  -- (assembled in Task 9)
end

if not _G.EH2_SUITEX_NO_RUN then SuiteX.run() end
return SuiteX
```

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add easyhover2_suitex.lua tests/test_suitex.lua tests/run_headless.sh
git commit -m "feat(suitex): scaffold guarded single-file program + test harness"
```

---

### Task 4: Theme (light/dark palettes)

**Files:** Modify `easyhover2_suitex.lua`; Test `tests/test_suitex.lua`.

**Interfaces:**
- Produces: `SuiteX.theme.palettes.{dark,light}` (maps of role→`colours.*`); `SuiteX.theme.get(mode)` → palette (dark fallback); `SuiteX.theme.roleColour(pal, plan)` → colour.

- [ ] **Step 1: Failing test**

```lua
t.test("theme has matching high-contrast light/dark palettes", function()
  local d, l = SuiteX.theme.palettes.dark, SuiteX.theme.palettes.light
  for _, key in ipairs({ "bg","panel","text","dim","border","accent","ok","update","repair","error","install","btn","btnText","btnActive","btnDisabled" }) do
    t.truthy(d[key] ~= nil, "dark has " .. key); t.truthy(l[key] ~= nil, "light has " .. key)
  end
  t.truthy(d.bg ~= d.text, "dark bg != text"); t.truthy(l.bg ~= l.text, "light bg != text")
  t.eq(SuiteX.theme.get("nope"), SuiteX.theme.palettes.dark, "unknown mode -> dark")
end)

t.test("roleColour maps plan to a palette colour", function()
  local d = SuiteX.theme.palettes.dark
  t.eq(SuiteX.theme.roleColour(d, "current"), d.ok)
  t.eq(SuiteX.theme.roleColour(d, "update"), d.update)
  t.eq(SuiteX.theme.roleColour(d, "repair"), d.repair)
  t.eq(SuiteX.theme.roleColour(d, "install"), d.install)
end)
```

- [ ] **Step 2: Run — FAIL** (`SuiteX.theme` nil).

- [ ] **Step 3: Implement** (in `easyhover2_suitex.lua`)

```lua
SuiteX.theme = { palettes = {
  dark = { bg=colours.black, panel=colours.grey, text=colours.white, dim=colours.lightGrey,
    border=colours.lightGrey, accent=colours.cyan, ok=colours.lime, update=colours.yellow,
    repair=colours.orange, error=colours.red, install=colours.cyan, btn=colours.grey,
    btnText=colours.white, btnActive=colours.lime, btnDisabled=colours.grey },
  light = { bg=colours.white, panel=colours.lightGrey, text=colours.black, dim=colours.grey,
    border=colours.grey, accent=colours.blue, ok=colours.green, update=colours.orange,
    repair=colours.brown, error=colours.red, install=colours.blue, btn=colours.lightGrey,
    btnText=colours.black, btnActive=colours.green, btnDisabled=colours.lightGrey },
} }
function SuiteX.theme.get(mode) return SuiteX.theme.palettes[mode] or SuiteX.theme.palettes.dark end
function SuiteX.theme.roleColour(pal, plan)
  if plan == "current" then return pal.ok elseif plan == "update" then return pal.update
  elseif plan == "repair" then return pal.repair elseif plan == "install" then return pal.install
  else return pal.text end
end
```

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(suitex): light/dark theme palettes`.

---

### Task 5: Plan view model (status lines + button states)

**Files:** Modify `easyhover2_suitex.lua`; Test `tests/test_suitex.lua`.

**Interfaces:**
- Produces: `SuiteX.buttonStates(plan)` → `{go,verify,repair,switch,tools,quit = "active"|"disabled"}`; `SuiteX.planView(ctx)` → `{ lines = { {label,value,role?} ... }, buttons = <buttonStates> }`. `ctx = { role, state={version}, manifest={version}, plan, report={missing,corrupt,total}, diffLabel }`.

- [ ] **Step 1: Failing test**

```lua
t.test("buttonStates: Go disabled only when already current", function()
  t.eq(SuiteX.buttonStates("update").go, "active")
  t.eq(SuiteX.buttonStates("current").go, "disabled")
  t.eq(SuiteX.buttonStates("current").verify, "active")
end)

t.test("planView builds status lines with the plan-aware diff label", function()
  local v = SuiteX.planView({ role="fcs", state={version="a"}, manifest={version="b"}, plan="update",
    report={ missing={}, corrupt={"x","y"}, total=10, present=10 }, diffLabel="outdated" })
  local byLabel = {}; for _,l in ipairs(v.lines) do byLabel[l.label]=l end
  t.eq(byLabel.installed.value, "a"); t.eq(byLabel.release.value, "b")
  t.eq(byLabel.plan.role, "update")
  t.eq(byLabel.files.value, "8 ok / 0 missing / 2 outdated")
  t.eq(v.buttons.go, "active")
end)
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement**

```lua
function SuiteX.buttonStates(plan)
  return { go = (plan == "current") and "disabled" or "active",
    verify = "active", repair = "active", switch = "active", tools = "active", quit = "active" }
end
function SuiteX.planView(ctx)
  local r = ctx.report or { missing={}, corrupt={}, total=0, present=0 }
  local diff = #(r.corrupt or {})
  local ok = math.max(0, (r.total or 0) - #(r.missing or {}) - diff)
  return {
    lines = {
      { label="role", value = ctx.role or "?" },
      { label="installed", value = (ctx.state and ctx.state.version) or "none" },
      { label="release", value = (ctx.manifest and ctx.manifest.version) or "?" },
      { label="plan", value = ctx.plan or "?", role = ctx.plan },
      { label="files", value = ("%d ok / %d missing / %d %s"):format(ok, #(r.missing or {}), diff, ctx.diffLabel or "outdated") },
    },
    buttons = SuiteX.buttonStates(ctx.plan),
  }
end
```

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(suitex): plan/status view model`.

---

### Task 6: Incremental integrity check driver

**Files:** Modify `easyhover2_suitex.lua`; Test `tests/test_suitex.lua`.

**Interfaces:**
- Produces: `SuiteX.checkDriver(files, checkOne)` → stepper with `.step(n)`→`done:boolean`, `.progress()`→`(i,total)`, `.result()`→`{missing,corrupt,present,total,ok}`. `checkOne(entry)`→`"ok"|"missing"|"corrupt"` (SuiteX wires it to `Suite.checkFile(entry, Suite.readFile)` at runtime).

- [ ] **Step 1: Failing test**

```lua
t.test("checkDriver steps to completion and reports like a one-shot check", function()
  local files = { {dst="a"},{dst="b"},{dst="c"},{dst="d"} }
  local verdict = { a="ok", b="corrupt", c="ok", d="missing" }
  local drv = SuiteX.checkDriver(files, function(e) return verdict[e.dst] end)
  local done = drv.step(2); t.eq(done, false)
  local i, total = drv.progress(); t.eq(i, 2); t.eq(total, 4)
  done = drv.step(10); t.eq(done, true)               -- clamps past the end
  local r = drv.result()
  t.eq(#r.corrupt, 1); t.eq(#r.missing, 1); t.eq(r.present, 3); t.eq(r.total, 4); t.eq(r.ok, false)
end)
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement**

```lua
function SuiteX.checkDriver(files, checkOne)
  local self = { files = files or {}, checkOne = checkOne, i = 0,
    report = { missing = {}, corrupt = {}, present = 0, total = #(files or {}) } }
  function self.step(n)
    local stop = math.min(self.i + (n or 1), #self.files)
    while self.i < stop do
      self.i = self.i + 1
      local e = self.files[self.i]; local v = self.checkOne(e)
      if v == "missing" then self.report.missing[#self.report.missing+1] = e.dst
      else self.report.present = self.report.present + 1
        if v == "corrupt" then self.report.corrupt[#self.report.corrupt+1] = e.dst end end
    end
    return self.i >= #self.files
  end
  function self.progress() return self.i, #self.files end
  function self.result()
    self.report.ok = (#self.report.missing == 0 and #self.report.corrupt == 0)
    return self.report
  end
  return self
end
```

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(suitex): incremental integrity check driver`.

---

### Task 7: EH2 logo (data)

**Files:** Modify `easyhover2_suitex.lua`; Test `tests/test_suitex.lua`.

**Interfaces:**
- Produces: `SuiteX.logo` → array of equal-length ASCII strings (a blocky "EH2" / "EasyHover 2" wordmark) for the main menu; `SuiteX.logoSize()` → `(width, height)`.

- [ ] **Step 1: Failing test**

```lua
t.test("logo is a rectangular ASCII block", function()
  t.truthy(#SuiteX.logo >= 1, "has rows")
  local w = #SuiteX.logo[1]
  for _, row in ipairs(SuiteX.logo) do t.eq(#row, w, "rows equal width") end
  local lw, lh = SuiteX.logoSize(); t.eq(lw, w); t.eq(lh, #SuiteX.logo)
  t.truthy(w <= 49, "fits a 51-wide terminal with margin")
end)
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** — an ASCII wordmark (refined visually later per the spec). Example placeholder-quality-but-valid content to satisfy the contract; polish the glyphs at UI time:

```lua
SuiteX.logo = {
  "  ___ _  _ ___    ___ ",
  " | __| || |_  )  |__ \\",
  " | _|| __ |/ /     /_/",
  " |___|_||_/___|   (o) ",
}
function SuiteX.logoSize() return #SuiteX.logo[1], #SuiteX.logo end
```

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(suitex): EH2 logo block`.

---

### Task 8: Bootstrap decision logic (ensure-basalt)

**Files:** Modify `easyhover2_suitex.lua`; Test `tests/test_suitex.lua`.

**Interfaces:**
- Produces: `SuiteX.basaltAction(localBody, want)` → `"use"|"fetch"` — pure decision: `"use"` iff `localBody` is non-nil and matches `want = {size, sum}` by size + `Suite.checksum`; else `"fetch"`. (The fs/http/`load` wrapping lives in `run()`, Task 9, and uses this decision. `Suite.checksum` is injected for the test.)

- [ ] **Step 1: Failing test**

```lua
t.test("basaltAction: use cached only on an exact size+sum match", function()
  local sum = function(s) return #s == 3 and "GOOD" or "BAD" end
  local want = { size = 3, sum = "GOOD" }
  t.eq(SuiteX.basaltAction("abc", want, sum), "use")
  t.eq(SuiteX.basaltAction(nil, want, sum), "fetch", "missing -> fetch")
  t.eq(SuiteX.basaltAction("abcd", want, sum), "fetch", "size mismatch -> fetch")
  t.eq(SuiteX.basaltAction("abX", { size=3, sum="GOOD" }, function() return "BAD" end), "fetch", "sum mismatch -> fetch")
end)
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement**

```lua
function SuiteX.basaltAction(localBody, want, checksum)
  if localBody ~= nil and want and #localBody == want.size and checksum(localBody) == want.sum then
    return "use"
  end
  return "fetch"
end
```

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(suitex): basalt cache/fetch decision`.

---

### Task 9: Basalt UI assembly + `run()` entry (glue, in-game verified)

**Files:** Modify `easyhover2_suitex.lua`.

**Interfaces:**
- Consumes: everything above + the classic engine (`Suite.fetch`, `Suite.readFile`, `Suite.base`, `Suite.STATE_FILE`, `Suite.parseState`, `Suite.detectRole`, `Suite.choosePlan`, `Suite.performPlan`, `Suite.checkFile`, `Suite.diffLabel`, `Suite.diagTools`, `Suite.askForRole`, `Suite.emit`/`Suite.sink`).
- Produces: `SuiteX.run()` — the full program.

> This task is glue; the pure logic it drives is already tested. Verify by parse + single-frame render + in-game smoke. **Confirm every Basalt element/method name against the vendored source, not memory:** `grep` `release/basalt-full.lua` (and the Basalt repo `src/elements/` if needed) for the elements used (baseframe/frame, tabs/menu, button, dropdown/list, label, progressbar, and `:setBackground`/`:onClick`/`:setText` equivalents). Never call `basalt.run()` in tests.

- [ ] **Step 1: Terminal gate + bootstrap** — write `SuiteX.run()`:
  1. If `not term.isColour()` → `print("EasyHover 2 SuiteX needs an advanced (colour) terminal. Run the classic easyhover2_suite.lua instead.")`; `return`.
  2. Load the engine: fetch `<base>/easyhover2_suite.lua` (reuse a minimal inline `http.get` + cache-bust, or bootstrap by fetching once), `load(body, "=suite", "t", setmetatable({ EH2_SUITE_NO_RUN = true }, { __index = _G }))()` → capture `Suite`. Abort with a clear message if load fails.
  3. Fetch `<base>/manifest.lua`; `Suite = ...` already loaded; `manifest = textutils.unserialise(fetch(base.."/manifest.lua"))`.
  4. Ensure Basalt: `local localB = <read /basalt-full.lua>`; if `SuiteX.basaltAction(localB, manifest.basalt, Suite.checksum) == "fetch"` then fetch `<base>/release/basalt-full.lua`, verify size+sum, write `/basalt-full.lua` (abort on re-mismatch). `local basalt = dofile("/basalt-full.lua")` (or `load` the verified body).

- [ ] **Step 2: State + plan** — mirror `Suite.main`'s non-UI computation:
  `state = Suite.parseState(Suite.readFile(Suite.STATE_FILE))`; `detected = Suite.detectRole(manifest, fs.exists, Suite.readFile)`; `role = state.role or detected` (or `Suite.askForRole(manifest, order)` via a Basalt dropdown if none); `spec = manifest.roles[role]`.

- [ ] **Step 3: Build the Basalt tree** — a main frame themed from `SuiteX.theme.get(mode)`:
  - Header with `SuiteX.logo` (drawn as themed labels), a light/dark toggle button (flips `mode`, re-applies palette to all elements), and a tab strip (Main / Advanced).
  - **Main tab:** a status/findings panel (rendered from `SuiteX.planView(ctx).lines`, each line coloured via `SuiteX.theme.roleColour`), a progress bar, a scrolling log panel, and the action buttons (Go/Verify/Repair/Switch/Launch/Quit) with enabled/colour per `SuiteX.planView(ctx).buttons`.
  - **Advanced tab:** a single disabled/"coming soon" label (placeholder).

- [ ] **Step 4: Wire the async check** — set `SuiteX.check = SuiteX.checkDriver(spec.files, function(e) return Suite.checkFile(e, Suite.readFile) end)`. Drive it from a Basalt timer/thread: each tick call `check.step(8)`, update the progress bar from `check.progress()`; when done, compute `ctx = { role, state, manifest, plan = Suite.choosePlan{ anyInstall = report.present>0, mismatched = not report.ok, sameVersion = (state.version==manifest.version), noRecord = state.version==nil }, report = check.result(), diffLabel = Suite.diffLabel(plan) }`, refresh the status panel + button states, and enable the buttons. The menu is interactive throughout (never blocks).

- [ ] **Step 5: Wire actions** — set `Suite.sink = function(text, c) <append to the log panel> end` for the duration of an engine op. Go → `pcall(Suite.performPlan, Suite.base, manifest, spec, role, plan, report.present==0)`; Verify → re-arm the check driver; Repair → `performPlan(..., "repair", ...)`; Switch → role dropdown then recompute; Launch → dropdown of `Suite.diagTools(spec)` then `shell.run(name)`; Quit → `basalt.stop()`/exit. After any op, clear `Suite.sink` and re-run the check so findings reflect the new state.

- [ ] **Step 6: Parse + single-frame render check**

Run (headless):
```bash
DATA="$(mktemp -d)"; C="$DATA/computer/0"; mkdir -p "$C"; cp -r fcs tools ui release easyhover2_suite.lua easyhover2_suitex.lua manifest.lua "$C/"
cat > "$C/startup.lua" <<'LUA'
local ok,err = pcall(function()
  _G.EH2_SUITEX_NO_RUN = true
  local SX = require("easyhover2_suitex")            -- must load clean
  local basalt = dofile("/release/basalt-full.lua")  -- vendored build loads
  assert(type(basalt)=="table")
end)
local h=fs.open("/results.txt","w"); h.write(ok and "OK" or ("ERR "..tostring(err))); h.close(); os.shutdown()
LUA
timeout 60 "/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe" --headless -d "$DATA" >/dev/null 2>&1 || true
cat "$C/results.txt"
```
Expected: `OK`. Then `bash tests/run_headless.sh` still green.

- [ ] **Step 7: Commit**

```bash
git add easyhover2_suitex.lua
git commit -m "feat(suitex): Basalt UI -- themed main menu, async check, engine-driven actions"
```

- [ ] **Step 8: In-game smoke (user)** — `wget run <repo>/easyhover2_suitex.lua`: boots to the themed main menu with logo; status fills in with a progress bar; light/dark toggle works with good contrast; Go/Verify/Repair/Switch/Launch/Quit drive the engine; screenshots fed back for visual confirmation of the logo/menu.

---

## Self-Review

- **Spec coverage:** coexistence/untouched-classic (Task 1 additive-only; Global Constraints) ✓; bootstrap fetch/cache basalt + load engine (Tasks 2, 9) ✓; engine reuse via `EH2_SUITE_NO_RUN` + exposed helpers + sink (Tasks 1, 9) ✓; main menu regardless of state + logo + theme toggle (Tasks 4, 7, 9) ✓; async chunked check + findings (Tasks 6, 9) ✓; action buttons/plan colours (Tasks 5, 9) ✓; advanced placeholder tab (Task 9) ✓; vendored basalt + manifest verify (Task 2) ✓; basic-terminal fallback (Task 9 Step 1) ✓; testing strategy (pure modules TDD; Basalt single-frame + in-game) ✓.
- **Placeholder scan:** the logo glyphs are explicitly a valid-but-refine-later block (spec defers final look to screenshots); every other step has concrete code or a concrete command. Basalt element method names are deferred to the vendored source by design (source-of-truth grep), not guessed.
- **Type consistency:** `SuiteX.checkDriver(files, checkOne)`, `basaltAction(localBody, want, checksum)`, `planView(ctx)`/`buttonStates(plan)`, `theme.get`/`roleColour`, and the `Suite.*` names (`fetch`/`readFile`/`STATE_FILE`/`base`/`checkFile`/`emit`/`sink`) are used consistently across tasks.
