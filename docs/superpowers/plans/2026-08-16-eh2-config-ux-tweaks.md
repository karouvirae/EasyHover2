# EH2 Config UX Tweaks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship three UI/tool tweaks in the EH2 config area — readable multi-row/glyph buttons (MDB-Conf + DTC), an FCS→UI config import via a shared networked disk, and a DTC disk SCAN + CLEAN — without touching frozen flight code.

**Architecture:** All disk IO flows through deps-injected seams so every core function is headless-testable with an in-memory store. Feature 1 reuses `configkit.actionRow` per-row (never rewrites it). Feature 2 adds a standalone FCS console tool (shaped like `tools/splitconfig.lua`) plus a UI `IMPORT ALL`. Feature 3 adds pure `M._scanDisk`/`M._cleanDisk`/`M._scanSummary` DTC seams + UI wiring.

**Tech Stack:** CC:Tweaked Lua (MC 1.21.1), Basalt 2.0 (full build only), CraftOS-PC headless self-test, `tests.framework` (`t.test`/`t.eq`/`t.truthy`), SuiteX installer + `gen_manifest.lua`/`build.mjs` dist pipeline.

## Global Constraints

- **No frozen flight-code changes.** `fcs/**` flight/kernel untouched; the FCS tool is a STANDALONE console program (like `tools/splitconfig.lua`), not a flight-app edit.
- **Reuse, don't reinvent:** `configkit.actionRow` (call per-row), DTC `M._scanKind/_importKind/validateKind/KINDS/FILE/resolveDeps`, `tools/splitconfig.lua` shape, SuiteX `toolsToInstall`/`checkboxLabels`/`installToolIfRequested`/`installOneTool`.
- **Glyph caveat:** CC:Tweaked font may not render `⟳`/`✓`/`✕`. Use CC-native chars where they exist (`"\27"`=←). Any uncertain glyph is a NAMED CONSTANT the user confirms in-game (PFD-horizon pattern: `horizon.lua` `M.STYLE.subpixel.pair = "\140 "`), with a short-word fallback (`OK`, `RE-SCAN`, `CANCEL`). Prefer a short word over an unrenderable glyph.
- **Filenames never hardcoded:** FCS kinds via `cfgspec.FILES[kind]`; DTC via `M.FILE`.
- **TDD every task:** write the failing test FIRST and run RED before editing a manifested impl file (tests aren't manifested → sync-guard stays green). Commit SOURCE + tests per task; leave `manifest*.lua`/`dist` dirty until the final build task (Task Z).
- **Gates (all three green before merge):** `bash tests/run_headless.sh`, `bash tests/run_headless_dist.sh`, `bash tests/run_suite_e2e.sh`. New `tests/test_*` register in BOTH `tests/run_headless.sh` and `tests/run_headless_dist.sh`.
- **Commit footer EXACTLY:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Test harness:** `package.path = "/?.lua;/?/init.lua;" .. package.path` then `local t = require("tests.framework")`. Run a single suite headless with `bash tests/run_headless.sh` (whole suite) — there is no per-file runner; add your test module to the `suites` list in `tests/run_headless.sh` to exercise it, and RED = the new `t.test` case fails while the rest pass.

---

## File structure

**Feature 1 (buttons):**
- Modify `ui/basalt/configkit.lua` — add `M.GLYPH` named-constant table (BACK/RESCAN/REFRESH/CONFIRM_OK/CONFIRM_CANCEL).
- Modify `ui/basalt/bitconfig/mdb.lua` — `buildOverview` footer → multi-row.
- Modify `ui/basalt/bitconfig/dtc.lua` — `buildTop` → multi-row (also hosts Feature 2/3 buttons).
- Modify `tests/test_configkit.lua`, `tests/test_bitconfig_mdb.lua`, `tests/test_bitconfig_dtc.lua`.

**Feature 2 (FCS→UI import):**
- Create `tools/fcs2disk.lua`, `launchers/fcs2disk.lua`, `tests/test_fcs2disk.lua`.
- Modify `easyhover2_suitex.lua` (SuiteX wiring), `tools/gen_manifest.lua` (`TOOLS` entry), `tests/test_suitex.lua`.
- Modify `ui/basalt/bitconfig/dtc.lua` (`M._importAll` + `IMPORT ALL` + `confirm_importall`), `tests/test_bitconfig_dtc.lua`.

**Feature 3 (SCAN/CLEAN):**
- Modify `ui/basalt/bitconfig/dtc.lua` (`resolveDeps.list`, `realList`, `M._scanDisk`, `M._cleanDisk`, `M._scanSummary`, SCAN/CLEAN UI), `tests/test_bitconfig_dtc.lua`.

**Final build:**
- Modify `tests/run_headless.sh`, `tests/run_headless_dist.sh`; regenerate `manifest*.lua`/`dist`.

---

# Phase A — Feature 1: Readable multi-row / glyph buttons

### Task A1: Named glyph/label constants in configkit

**Files:**
- Modify: `ui/basalt/configkit.lua` (add `M.GLYPH` near the top of the Basalt-chrome section, ~line 195)
- Test: `tests/test_configkit.lua`

**Interfaces:**
- Produces: `configkit.GLYPH = { BACK, RESCAN, REFRESH, CONFIRM_OK, CONFIRM_CANCEL }` (all strings). `BACK` is the CC-native left-arrow `"\27"`. The rescan/refresh/confirm entries are short-word fallbacks by default (safe to render), flippable to a glyph after in-game confirmation.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_configkit.lua`:
```lua
t.test("GLYPH: BACK is the CC-native left arrow; others are safe short-word fallbacks", function()
  t.eq(configkit.GLYPH.BACK, "\27")               -- CC-native left arrow, always renders
  t.eq(configkit.GLYPH.RESCAN, "RE-SCAN")         -- word fallback (flip to a glyph only after in-game confirm)
  t.eq(configkit.GLYPH.REFRESH, "REFRESH")
  t.eq(configkit.GLYPH.CONFIRM_OK, "OK")
  t.eq(configkit.GLYPH.CONFIRM_CANCEL, "\27")     -- cancel reuses BACK's arrow
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh` (test_configkit is already in the suites list)
Expected: FAIL — `configkit.GLYPH` is nil.

- [ ] **Step 3: Write minimal implementation**

In `ui/basalt/configkit.lua`, just after `local M = {}` (line 11) add:
```lua
-- M.GLYPH: named button glyph/label constants (Feature 1). CC:Tweaked's font does NOT reliably
-- render ⟳/✓/✕, so every non-native action ships a short WORD by default; flip an entry to a real
-- glyph ONLY after confirming it renders in-game (same discipline as horizon.lua M.STYLE.subpixel).
-- BACK is the CC-native left arrow "\27", which always renders.
M.GLYPH = {
  BACK           = "\27",       -- ← (CC-native, safe)
  RESCAN         = "RE-SCAN",   -- word fallback; a glyph candidate can replace this after in-game confirm
  REFRESH        = "REFRESH",   -- word fallback
  CONFIRM_OK     = "OK",        -- no safe native ✓
  CONFIRM_CANCEL = "\27",       -- reuse BACK's ← for cancel
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/configkit.lua tests/test_configkit.lua
git commit -m "feat(configkit): named glyph/label constants for readable action buttons

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A2: MDB-Conf overview footer → multi-row

**Files:**
- Modify: `ui/basalt/bitconfig/mdb.lua:267-271` (`buildOverview` footer)
- Test: `tests/test_bitconfig_mdb.lua`

**Interfaces:**
- Consumes: `configkit.GLYPH` (Task A1), `configkit.actionRow`.
- Produces: `buildOverview`'s handle `elements` now exposes `saveRow` (1 button: SAVE), `footerRow` (2 buttons: RESCAN, BACK) instead of a single 3-button `footerRow`. `rescan` (the `doRescan` fn) still exposed.

- [ ] **Step 1: Write the failing test**

In `tests/test_bitconfig_mdb.lua`, find the construction-probe test that asserts the overview footer shape and REPLACE its footer assertions (and add if absent) with:
```lua
t.test("overview footer: SAVE on its own full-width row, then RESCAN + BACK on a second row", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local h = M.build(basalt, frame, nil, nav,
    function() return nil end,          -- read: no saved cfg
    function() end,                     -- write
    function() return {} end)           -- scan: no descriptors
  local els = h.elements.region.built.overview.handle.elements
  t.truthy(els.saveRow ~= nil and #els.saveRow.buttons == 1, "SAVE alone on its own row")
  t.eq(els.saveRow.buttons[1].button:getText(), "SAVE")
  t.truthy(els.footerRow ~= nil and #els.footerRow.buttons == 2, "RESCAN + BACK share the second row")
  t.eq(els.footerRow.buttons[2].button:getText(), "\27", "BACK is the CC-native left arrow")
  t.truthy(type(els.rescan) == "function", "doRescan still exposed for direct-invoke tests")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `els.saveRow` is nil (footer is still one 3-button row).

- [ ] **Step 3: Write minimal implementation**

In `ui/basalt/bitconfig/mdb.lua` `buildOverview`, replace the single `footerRow` block (lines 267-271) with:
```lua
    local configkitGlyph = configkit.GLYPH
    local saveRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "SAVE", onClick = function() M._save(workingCfg, write) end },
    })
    y = y + 1
    local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkitGlyph.RESCAN, onClick = doRescan },
      { label = configkitGlyph.BACK,   onClick = function() if nav then nav:pop() end end },
    })
```
Then update the `return`'s `elements` to include `saveRow`:
```lua
    return { apply = apply, elements = { groupBtns = groupBtns, saveRow = saveRow, footerRow = footerRow, rescan = doRescan } }
```
Note: `doRescan` is declared just above the old footer — keep that declaration in place; the new `saveRow`/`footerRow` reference it and `M._save`/`nav` exactly as before.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS (including any pre-existing MDB save/parity tests — SAVE still calls `M._save(workingCfg, write)`).

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/mdb.lua tests/test_bitconfig_mdb.lua
git commit -m "feat(mdb): split overview footer into readable SAVE + RESCAN/BACK rows

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A3: DTC top screen → multi-row (EXPORT/IMPORT + REFRESH placeholder rows)

**Files:**
- Modify: `ui/basalt/bitconfig/dtc.lua:490-522` (`buildTop`)
- Test: `tests/test_bitconfig_dtc.lua`

> This task lays out the multi-row skeleton and moves REFRESH onto its own row. The `SCAN`, `IMPORT ALL` buttons are added by Tasks B6/C3 into the rows established here.

**Interfaces:**
- Consumes: `configkit.GLYPH`, `configkit.actionRow`, existing `drive`/`doDetect`/`summaryText`.
- Produces: `buildTop`'s handle `elements` exposes `diskLabel`, `ioRow` (2 buttons: EXPORT, IMPORT), `refreshRow` (1 button: REFRESH), `backRow` (1 button: BACK). (Replaces the old `topRow` of 3.) `ioRow`/`refreshRow`/`backRow` each keep `.buttons` + `.setState`.

- [ ] **Step 1: Write the failing test**

The existing DTC probe tests reference `els.topRow` with 3 buttons (see `test_bitconfig_dtc.lua` ~lines 352-360, 403-404). UPDATE those two probes to the new shape and add a dedicated layout test:
```lua
t.test("top screen: EXPORT/IMPORT on one row, REFRESH on its own row, BACK its own row", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local deps = { find = function() return nil end, exists = function() return false end }
  local h = M.build(basalt, frame, nil, nav, deps)
  local els = h.elements.region.built.top.handle.elements
  t.truthy(els.ioRow ~= nil and #els.ioRow.buttons == 2, "EXPORT + IMPORT share a row")
  t.eq(els.ioRow.buttons[1].button:getText(), "EXPORT")
  t.eq(els.ioRow.buttons[2].button:getText(), "IMPORT")
  t.truthy(els.refreshRow ~= nil and #els.refreshRow.buttons == 1, "REFRESH on its own row")
  t.truthy(els.backRow ~= nil and #els.backRow.buttons == 1, "BACK its own row")
  t.eq(els.backRow.buttons[1].button:getText(), "\27", "BACK is CC-native left arrow")
  -- no disk -> EXPORT/IMPORT disabled, REFRESH enabled
  t.eq(els.ioRow.buttons[1].button:getEnabled(), false, "EXPORT disabled: no disk")
  t.eq(els.ioRow.buttons[2].button:getEnabled(), false, "IMPORT disabled: no disk")
  t.eq(els.refreshRow.buttons[1].button:getEnabled(), true, "REFRESH always enabled")
end)
```
In the two existing probes (`"M.build (no disk): ..."` and `"M.build (stub disk present): ..."`), replace every `els.topRow.buttons[1]`/`[2]` with `els.ioRow.buttons[1]`/`[2]` and every `els.topRow.buttons[3]` (REFRESH) with `els.refreshRow.buttons[1]`, and drop the `#els.topRow.buttons == 3` assertion.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `els.ioRow` is nil (still one `topRow` of 3).

- [ ] **Step 3: Write minimal implementation**

In `ui/basalt/bitconfig/dtc.lua` `buildTop`, replace the `topRow` + `backRow` blocks (lines 500-510) with:
```lua
    local ioRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "EXPORT", onClick = function() region:push("export") end },
      { label = "IMPORT", onClick = function() region:push("import") end },
    })
    y = y + 1

    local refreshRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkit.GLYPH.REFRESH, onClick = function() doDetect(); region:apply(nil) end },
    })
    y = y + 1

    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkit.GLYPH.BACK, onClick = function() if nav then nav:pop() end end },
    })
```
Update `refreshTop` to gate `ioRow` (was `topRow`):
```lua
    local function refreshTop()
      diskLabel:setText(clampText(summaryText(), fiw))
      ioRow.setState(1, drive.present and "off" or "disabled")
      ioRow.setState(2, drive.present and "off" or "disabled")
    end
```
Update the returned `elements`:
```lua
    return {
      apply = function(_state) refreshTop() end,
      elements = { diskLabel = diskLabel, ioRow = ioRow, refreshRow = refreshRow, backRow = backRow },
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS (updated probes + new layout test).

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/dtc.lua tests/test_bitconfig_dtc.lua
git commit -m "feat(dtc): split top screen into readable EXPORT/IMPORT + REFRESH + BACK rows

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

# Phase B — Feature 2: FCS→UI config import via shared disk

### Task B1: `fcs2disk` pure core (`M.plan`)

**Files:**
- Create: `tools/fcs2disk.lua`
- Create: `tests/test_fcs2disk.lua`

**Interfaces:**
- Produces: `tools.fcs2disk` with `M.plan(existing) -> { action, kinds, missing, err? }`.
  - `existing = { present = {devbind=bool, senscal=bool, tuning=bool}, mount = <string|nil> }`.
  - `action`: `"no-mount"` if `existing.mount == nil`; `"abort"` if a mount exists but NO kind is present; else `"write"`.
  - `kinds` = FCS kinds present (in `cfgspec.FILES` iteration order devbind, senscal, tuning), `missing` = FCS kinds absent.

- [ ] **Step 1: Write the failing test**

Create `tests/test_fcs2disk.lua`:
```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local F = require("tools.fcs2disk")

local KINDS = { "devbind", "senscal", "tuning" }

t.test("plan: all three present with a mount -> write all three, none missing", function()
  local r = F.plan({ present = { devbind = true, senscal = true, tuning = true }, mount = "disk" })
  t.eq(r.action, "write")
  t.eq(#r.kinds, 3); t.eq(#r.missing, 0)
  for i, k in ipairs(KINDS) do t.eq(r.kinds[i], k) end
end)

t.test("plan: some present -> writes present, lists missing (in cfgspec order)", function()
  local r = F.plan({ present = { devbind = true, tuning = true }, mount = "disk" })
  t.eq(r.action, "write")
  t.eq(#r.kinds, 2); t.eq(r.kinds[1], "devbind"); t.eq(r.kinds[2], "tuning")
  t.eq(#r.missing, 1); t.eq(r.missing[1], "senscal")
end)

t.test("plan: no mount -> no-mount action regardless of presence", function()
  t.eq(F.plan({ present = { devbind = true }, mount = nil }).action, "no-mount")
end)

t.test("plan: mount present but nothing local -> abort", function()
  t.eq(F.plan({ present = {}, mount = "disk" }).action, "abort")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Add `"tests.test_fcs2disk"` to the `suites` list in `tests/run_headless.sh`, then run `bash tests/run_headless.sh`.
Expected: FAIL — `tools.fcs2disk` module not found.

- [ ] **Step 3: Write minimal implementation**

Create `tools/fcs2disk.lua`:
```lua
-- tools/fcs2disk.lua
-- STANDALONE FCS console tool (SuiteX-installed like tools/splitconfig.lua -- NOT a flight-app
-- change): dumps the FCS's 3 local split config files (eh2_devbind/senscal/tuning) onto a shared
-- networked disk so the UI PC's DTC can IMPORT ALL them. PURE core here (plan()); the in-game
-- run() below resolves the drive + writes and is not headless-tested. Filenames NEVER hardcoded --
-- always cfgspec.FILES[kind].
local cfgspec = require("fcs.io.cfgspec")

local M = {}

-- FCS kinds this tool dumps, in cfgspec order (uicfg is UI-only and not on the FCS).
M.KINDS = { "devbind", "senscal", "tuning" }

-- plan(existing) -> { action, kinds, missing, err? }.
-- existing = { present = {kind=bool}, mount = <string|nil> }.
function M.plan(existing)
  existing = existing or {}
  local present = existing.present or {}
  if existing.mount == nil then return { action = "no-mount", kinds = {}, missing = {} } end
  local kinds, missing = {}, {}
  for _, k in ipairs(M.KINDS) do
    if present[k] == true then kinds[#kinds + 1] = k else missing[#missing + 1] = k end
  end
  if #kinds == 0 then return { action = "abort", kinds = kinds, missing = missing, err = "no local FCS configs to dump" } end
  return { action = "write", kinds = kinds, missing = missing }
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/fcs2disk.lua tests/test_fcs2disk.lua tests/run_headless.sh
git commit -m "feat(fcs2disk): pure plan() for dumping FCS configs to a shared disk

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B2: `fcs2disk` in-game `M.run` + launcher

**Files:**
- Modify: `tools/fcs2disk.lua`
- Create: `launchers/fcs2disk.lua`
- Test: `tests/test_fcs2disk.lua`

**Interfaces:**
- Consumes: `M.plan` (B1).
- Produces: `M.run(deps) -> string` (human summary). `deps`: `read`, `write`(atomic), `exists`, `find`(→drive). Resolves the drive via `deps.find("drive")` → `getMountPath()`; writes each present kind's local body to `<mount>/<cfgspec.FILES[kind]>`; returns a summary naming dumped + missing kinds.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fcs2disk.lua`:
```lua
-- in-memory deps store (mirrors test_splitconfig / test_bitconfig_dtc conventions)
local function fakeDeps(localFiles, mount)
  local files = {}
  for k, v in pairs(localFiles or {}) do files[k] = v end
  local drive = mount and {
    isDiskPresent = function() return true end,
    getMountPath  = function() return mount end,
  } or nil
  local deps = {
    find   = function(kind) return (kind == "drive") and drive or nil end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    write  = function(p, body) files[p] = body end,
  }
  return files, deps
end

t.test("run: dumps every present local kind to <mount>/<cfgspec.FILES[kind]>", function()
  local files, deps = fakeDeps({
    ["/eh2_devbind.tbl"] = "DB", ["/eh2_tuning.tbl"] = "TN",
  }, "disk")
  local summary = F.run(deps)
  t.eq(files["/disk/eh2_devbind.tbl"], "DB")
  t.eq(files["/disk/eh2_tuning.tbl"], "TN")
  t.eq(files["/disk/eh2_senscal.tbl"], nil, "senscal absent locally -> not written")
  t.truthy(summary:find("devbind", 1, true) and summary:find("senscal", 1, true),
    "summary names dumped + missing kinds: " .. summary)
end)

t.test("run: no drive found -> writes nothing, reports no-mount", function()
  local files, deps = fakeDeps({ ["/eh2_devbind.tbl"] = "DB" }, nil)
  local summary = F.run(deps)
  t.eq(files["/disk/eh2_devbind.tbl"], nil)
  t.truthy(summary:lower():find("disk", 1, true), "summary mentions the missing disk: " .. summary)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `F.run` is nil.

- [ ] **Step 3: Write minimal implementation**

Append to `tools/fcs2disk.lua` (before `return M`):
```lua
-- ---- in-game run: resolve the drive, dump present local kinds to the disk. Not headless-tested. ----
local fsx = require("fcs.io.fsx")

local function realExists(path) return fs.exists(path) and not fs.isDir(path) end
local function realFind(kind) return peripheral.find(kind) end

-- run(deps) -> human summary string. deps.read/write/exists default to fsx; deps.find to peripheral.find.
function M.run(deps)
  deps = deps or {}
  local read   = deps.read   or fsx.read
  local write  = deps.write  or fsx.writeAtomic
  local exists = deps.exists or realExists
  local find   = deps.find   or realFind

  local drive = find("drive")
  local mount = drive and drive.getMountPath and drive.getMountPath() or nil

  local present = {}
  for _, k in ipairs(M.KINDS) do present[k] = exists("/" .. cfgspec.FILES[k]) end

  local r = M.plan({ present = present, mount = mount })
  if r.action == "no-mount" then return "No disk drive/disk found -- nothing written. Insert the shared disk and retry." end
  if r.action == "abort" then return "ABORT: " .. tostring(r.err) .. " (nothing written)." end

  local wrote = {}
  for _, k in ipairs(r.kinds) do
    local body = read("/" .. cfgspec.FILES[k])
    if body ~= nil then
      write("/" .. mount .. "/" .. cfgspec.FILES[k], body)
      wrote[#wrote + 1] = k
    end
  end
  local missing = (#r.missing > 0) and (" (missing locally: " .. table.concat(r.missing, ", ") .. ")") or ""
  return "Dumped " .. table.concat(wrote, ", ") .. " to disk '" .. mount .. "'" .. missing .. "."
end
```
Create `launchers/fcs2disk.lua` (mirror `launchers/splitconfig.lua`'s shape — check that file for the exact print/idiom, typically):
```lua
-- launchers/fcs2disk.lua -- run on the FCS console to dump its 3 configs onto the shared disk.
local fcs2disk = require("tools.fcs2disk")
print(fcs2disk.run())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/fcs2disk.lua launchers/fcs2disk.lua tests/test_fcs2disk.lua
git commit -m "feat(fcs2disk): in-game run() dumps configs to disk + launcher

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B3: SuiteX Advanced-tab wiring for `fcs2disk`

**Files:**
- Modify: `easyhover2_suitex.lua` (`SuiteX.toolsToInstall` ~line 50; `installToolIfRequested` maps ~line 572; Advanced-tab checkbox ~line 712)
- Test: `tests/test_suitex.lua`

**Interfaces:**
- Consumes: `SuiteX.checkboxLabels`, `SuiteX.toolsToInstall`, `installToolIfRequested`, `installOneTool` (existing).
- Produces: `SuiteX.toolsToInstall({ installFcs2Disk = true })` includes `"fcs2disk"`. A new Advanced-tab checkbox sets `flags.installFcs2Disk`.

- [ ] **Step 1: Write the failing test**

In `tests/test_suitex.lua`, add (mirror the existing `installSplitConfig` case):
```lua
t.test("toolsToInstall includes fcs2disk when its flag is set", function()
  local out = SuiteX.toolsToInstall({ installFcs2Disk = true })
  local found = false
  for _, k in ipairs(out) do if k == "fcs2disk" then found = true end end
  t.truthy(found, "fcs2disk requested when installFcs2Disk flag set")
end)

t.test("toolsToInstall omits fcs2disk when its flag is unset", function()
  for _, k in ipairs(SuiteX.toolsToInstall({})) do t.truthy(k ~= "fcs2disk", "no fcs2disk unless flagged") end
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `fcs2disk` never in the list.

- [ ] **Step 3: Write minimal implementation**

In `easyhover2_suitex.lua`:
1. `SuiteX.toolsToInstall` (~line 54, after the `installSplitConfig` line):
```lua
  if flags.installFcs2Disk then out[#out + 1] = "fcs2disk" end
```
2. `installToolIfRequested` (~line 573): add `installFcs2Disk = <the Advanced-tab checkbox state>` to the flags table it passes to `SuiteX.toolsToInstall{…}`, and add entries to both maps:
```lua
  local doneMsg = {
    beaconupdate = "beacon updater installed -- run 'beaconupdate' to push updates to the beacons",
    splitconfig = "split-config tool installed -- run 'splitconfig' on the FCS to split a legacy fused config",
    fcs2disk = "FCS config-dump tool installed -- run 'fcs2disk' on the FCS to dump its configs to the shared disk",
  }
  local displayName = {
    beaconupdate = "beacon updater",
    splitconfig = "split-config tool",
    fcs2disk = "FCS config dump",
  }
```
3. Advanced-tab checkbox (~line 712, mirror the `splitOff/splitOn` block and wire the resulting checkbox state into the `flags.installFcs2Disk` the same way `installSplitConfig` is wired):
```lua
  local fcs2diskOff, fcs2diskOn = SuiteX.checkboxLabels("FCS config dump (dump FCS configs to disk)")
```
Follow the EXACT same checkbox-construction + flag-capture pattern the `Split config` checkbox uses in the surrounding code (read lines ~705-740 and replicate for `fcs2disk`).

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add easyhover2_suitex.lua tests/test_suitex.lua
git commit -m "feat(suitex): Advanced-tab checkbox to install the fcs2disk tool

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B4: Manifest `TOOLS` entry for `fcs2disk`

**Files:**
- Modify: `tools/gen_manifest.lua` (`TOOLS` table ~line 105)
- Test: `tests/test_manifest_tools.lua`

**Interfaces:**
- Consumes: `buildTool` (existing, ~line 266) which resolves the closure of `root`'s launcher.
- Produces: `TOOLS.fcs2disk = { title, entry = "fcs2disk", root = "launchers/fcs2disk.lua" }`, so the built manifest's `tools.fcs2disk` carries the tool + its file closure.

- [ ] **Step 1: Write the failing test**

In `tests/test_manifest_tools.lua` (mirror the existing `splitconfig` assertion), add:
```lua
t.test("manifest tools include fcs2disk with its launcher closure", function()
  local m = buildManifest()   -- use whatever this suite already calls to build the manifest table
  t.truthy(m.tools.fcs2disk ~= nil, "fcs2disk tool present in manifest")
  t.eq(m.tools.fcs2disk.entry, "fcs2disk")
  t.truthy(#m.tools.fcs2disk.files >= 1, "fcs2disk closure has files")
end)
```
(Match the exact manifest-building helper the existing `splitconfig` test in this file uses — read the file first.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `m.tools.fcs2disk` nil.

- [ ] **Step 3: Write minimal implementation**

In `tools/gen_manifest.lua` `TOOLS` (after the `splitconfig` entry at line 105-108), add:
```lua
  fcs2disk = {
    title = "FCS config dump",
    entry = "fcs2disk",
    root  = "launchers/fcs2disk.lua",
  },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/gen_manifest.lua tests/test_manifest_tools.lua
git commit -m "feat(manifest): register fcs2disk tool in the build closure

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B5: DTC `M._importAll` pure helper

**Files:**
- Modify: `ui/basalt/bitconfig/dtc.lua` (add `M._importAll` after `M._importKind`, ~line 363)
- Test: `tests/test_bitconfig_dtc.lua`

**Interfaces:**
- Consumes: `M.KINDS`, `M._scanKind`, `M._importKind`, `resolveDeps`.
- Produces: `M._importAll(mount, deps) -> { imported = {kinds…}, skipped = {kinds…} }` (M.KINDS order). Imports each kind where `_scanKind(mount,kind,deps).diskHas and .diskValid`; everything else is `skipped`. `mount == nil` → both empty.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_bitconfig_dtc.lua`:
```lua
t.test("_importAll: imports only valid disk kinds, backs up locals, skips the rest", function()
  local good = textutils.serialise({ gains = {}, caps = {}, feel = {} })   -- valid tuning
  local store = {
    ["/disk/eh2_tuning.tbl"]  = good,
    ["/disk/eh2_senscal.tbl"] = "corrupt {{{",   -- present but invalid
    ["/eh2_tuning.tbl"]       = "OLD-TUNING",
  }
  local backedUp = {}
  local deps = {
    exists = function(p) return store[p] ~= nil end,
    read   = function(p) return store[p] end,
    write  = function(p, b) store[p] = b end,
    delete = function(p) store[p] = nil end,
    move   = function(a, b) store[b] = store[a]; store[a] = nil end,
    attributes = function(p) return store[p] and { modified = 1 } or nil end,
    backup = function(p) backedUp[#backedUp + 1] = p end,
  }
  local r = M._importAll("disk", deps)
  t.eq(#r.imported, 1); t.eq(r.imported[1], "tuning")
  t.eq(store["/eh2_tuning.tbl"], good, "valid disk tuning imported over local")
  t.eq(backedUp[1], "/eh2_tuning.tbl", "local tuning backed up first")
  -- senscal present-but-invalid, devbind/uicfg absent -> all skipped
  local skippedSet = {}; for _, k in ipairs(r.skipped) do skippedSet[k] = true end
  t.truthy(skippedSet.senscal, "invalid senscal skipped")
  t.truthy(skippedSet.devbind and skippedSet.uicfg, "absent kinds skipped")
end)

t.test("_importAll: mount=nil -> nothing imported, nothing skipped-with-error", function()
  local r = M._importAll(nil, { exists = function() return true end })
  t.eq(#r.imported, 0)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `M._importAll` nil.

- [ ] **Step 3: Write minimal implementation**

In `ui/basalt/bitconfig/dtc.lua`, after `M._importKind` (line 363) add:
```lua
-- ===== M._importAll(mount, deps) -> { imported={kinds…}, skipped={kinds…} }: import every kind =====
-- ===== whose disk copy exists AND validates (reusing M._importKind's backup-then-copy); skip the
-- rest. M.KINDS order. mount == nil -> both empty. Feature 2's one-shot "IMPORT ALL".
function M._importAll(mount, deps)
  deps = resolveDeps(deps)
  local imported, skipped = {}, {}
  if mount == nil then return { imported = imported, skipped = skipped } end
  for _, kind in ipairs(M.KINDS) do
    local sk = M._scanKind(mount, kind, deps)
    if sk.diskHas and sk.diskValid and M._importKind(mount, kind, deps) then
      imported[#imported + 1] = kind
    else
      skipped[#skipped + 1] = kind
    end
  end
  return { imported = imported, skipped = skipped }
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/dtc.lua tests/test_bitconfig_dtc.lua
git commit -m "feat(dtc): M._importAll one-shot import of all valid disk configs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B6: DTC `IMPORT ALL` button + `confirm_importall` screen

**Files:**
- Modify: `ui/basalt/bitconfig/dtc.lua` (`buildTop` add button; add `buildImportAllConfirm` screen; register it in `screens`)
- Test: `tests/test_bitconfig_dtc.lua`

**Interfaces:**
- Consumes: `M._importAll` (B5), `configkit.actionRow`, `configkit.GLYPH`, `drive`/`doDetect`/`scanKindResults`, the `dirStatus` pattern.
- Produces: `buildTop` elements gain `importAllRow` (1 button: `IMPORT ALL`). A new region screen `"confirm_importall"` with elements `{ summaryLabel, confirmRow, backRow }`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_bitconfig_dtc.lua`:
```lua
t.test("M.build: IMPORT ALL button present; enabled only with a valid importable kind; "
  .. "CONFIRM imports all valid kinds and pops", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local good = textutils.serialise({ gains = {}, caps = {}, feel = {} })
  local files = { ["/disk/eh2_tuning.tbl"] = good }
  local fakeDrive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local deps = {
    find = function(k) return k == "drive" and fakeDrive or nil end,
    exists = function(p) return files[p] ~= nil end,
    read = function(p) return files[p] end,
    write = function(p, b) files[p] = b end,
    delete = function(p) files[p] = nil end,
    move = function(a, b) files[b] = files[a]; files[a] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
    backup = function(p) end,
  }
  local h = M.build(basalt, frame, nil, nav, deps)
  local region = h.elements.region
  local top = region.built.top.handle.elements
  t.truthy(top.importAllRow ~= nil and #top.importAllRow.buttons == 1, "IMPORT ALL present")
  t.eq(top.importAllRow.buttons[1].button:getEnabled(), true, "enabled: one valid disk kind exists")

  region:push("confirm_importall"); h.apply({})
  local cEls = region.built.confirm_importall.handle.elements
  cEls.confirmRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  h.apply({})
  t.eq(region:top(), "top", "CONFIRM pops back to top")
  t.eq(files["/eh2_tuning.tbl"], good, "IMPORT ALL brought the valid tuning local")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `top.importAllRow` nil / `confirm_importall` unbuilt.

- [ ] **Step 3: Write minimal implementation**

In `ui/basalt/bitconfig/dtc.lua`:
1. Add an `importAllRow` in `buildTop` (after `refreshRow`, before `backRow`), plus enable-gating in `refreshTop`:
```lua
    local importAllRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "IMPORT ALL", onClick = function() region:push("confirm_importall") end },
    })
    y = y + 1
```
In `refreshTop`, after the `ioRow` gating add:
```lua
      local anyValid = false
      for _, kind in ipairs(M.KINDS) do
        if scanKindResults[kind].diskHas and scanKindResults[kind].diskValid then anyValid = true end
      end
      importAllRow.setState(1, (drive.present and anyValid) and "off" or "disabled")
```
Add `importAllRow` to `buildTop`'s returned `elements`.
2. Add a confirm-screen builder (near `buildConfirm`, ~line 632):
```lua
  local function buildImportAllConfirm(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx, fiw, y = 2, math.max(1, ({ f:getSize() })[1] - 2), 1
    local summaryLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1
    local statusLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1
    local confirmRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkit.GLYPH.CONFIRM_OK, onClick = function()
          local r = M._importAll(drive.mount, deps)
          dirStatus.import = "IMPORT ALL: " .. #r.imported .. " imported, " .. #r.skipped .. " skipped"
          doDetect(); region:pop(); region:apply(nil)
        end },
    })
    y = y + 1
    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkit.GLYPH.CONFIRM_CANCEL, onClick = function() region:pop() end },
    })
    local function refresh()
      local n = 0
      for _, kind in ipairs(M.KINDS) do
        if scanKindResults[kind].diskHas and scanKindResults[kind].diskValid then n = n + 1 end
      end
      summaryLabel:setText(clampText("Import " .. n .. " valid config(s) to this UI PC?", fiw))
    end
    refresh()
    return { apply = function(_s) refresh() end,
      elements = { summaryLabel = summaryLabel, statusLabel = statusLabel, confirmRow = confirmRow, backRow = backRow } }
  end
```
3. Register it in the `screens` table (line 634):
```lua
  screens.confirm_importall = buildImportAllConfirm
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/dtc.lua tests/test_bitconfig_dtc.lua
git commit -m "feat(dtc): IMPORT ALL button + one-confirm import-all screen

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

# Phase C — Feature 3: DTC disk SCAN + CLEAN

### Task C1: `resolveDeps.list` + `M._scanDisk`

**Files:**
- Modify: `ui/basalt/bitconfig/dtc.lua` (`realList` near the other real seams ~line 207; `resolveDeps` ~line 259; add `M._scanDisk`)
- Test: `tests/test_bitconfig_dtc.lua`

**Interfaces:**
- Consumes: `deps.list` (new, default `realList` → `fs.list`), `M.FILE`, `M.validateKind`, `deps.exists/read`.
- Produces: `M._scanDisk(mount, deps) -> { valid = {kinds…}, foreign = {paths…}, invalid = {paths…} }`. `valid` = filename ∈ `M.FILE` and body unserialises + `validateKind` passes (collect the KIND); `invalid` = an EH2-named file (`M.FILE` value) that is missing-bodied/unparseable/fails validation (collect the PATH `<mount>/<name>`); `foreign` = any other filename (collect the PATH). `mount == nil` → all empty.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_bitconfig_dtc.lua`:
```lua
local function scanDeps(mount, byName)
  -- byName: { ["eh2_tuning.tbl"] = "<body>", ["foo.txt"] = "x", ... }
  local files = {}
  for name, body in pairs(byName) do files["/" .. mount .. "/" .. name] = body end
  local names = {}; for name in pairs(byName) do names[#names + 1] = name end
  return {
    list   = function(p) return (p == mount or p == "/" .. mount) and names or {} end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
  }
end

t.test("_scanDisk: classifies valid EH2 config, invalid EH2 file, and foreign file", function()
  local good = textutils.serialise({ gains = {}, caps = {}, feel = {} })  -- valid tuning
  local deps = scanDeps("disk", {
    ["eh2_tuning.tbl"]  = good,           -- valid
    ["eh2_senscal.tbl"] = "corrupt {{{",  -- EH2-named but invalid
    ["notes.txt"]       = "hello",        -- foreign
  })
  local s = M._scanDisk("disk", deps)
  t.eq(#s.valid, 1); t.eq(s.valid[1], "tuning")
  t.eq(#s.invalid, 1); t.truthy(s.invalid[1]:find("eh2_senscal.tbl", 1, true), s.invalid[1])
  t.eq(#s.foreign, 1); t.truthy(s.foreign[1]:find("notes.txt", 1, true), s.foreign[1])
end)

t.test("_scanDisk: mount=nil -> everything empty", function()
  local s = M._scanDisk(nil, { list = function() return { "x" } end })
  t.eq(#s.valid, 0); t.eq(#s.invalid, 0); t.eq(#s.foreign, 0)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `M._scanDisk` nil.

- [ ] **Step 3: Write minimal implementation**

In `ui/basalt/bitconfig/dtc.lua`:
1. Add `realList` near `realFind` (~line 184):
```lua
-- realList(path) -> array of filenames in a dir (nil/absence-safe: missing/invalid path -> {}).
local function realList(path)
  if not path or not fs.exists(path) or not fs.isDir(path) then return {} end
  return fs.list(path)
end
```
2. In `resolveDeps` (line 259), add the `list` default:
```lua
    list = deps.list or realList,
```
3. Add a filename→kind reverse map + `M._scanDisk` (after `M._scan`, ~line 243):
```lua
-- M.FILE reverse lookup: filename -> kind (built once from M.FILE). EH2-named iff FILE_KIND[name].
local FILE_KIND = {}
for kind, name in pairs(M.FILE) do FILE_KIND[name] = kind end

-- ===== M._scanDisk(mount, deps) -> { valid={kinds…}, foreign={paths…}, invalid={paths…} }. =====
-- Classify every file on the disk: valid EH2 config (collect the KIND), invalid EH2-named file
-- (collect the PATH), or foreign (collect the PATH). mount == nil -> all empty. Feature 3 SCAN.
function M._scanDisk(mount, deps)
  deps = resolveDeps(deps)
  local out = { valid = {}, foreign = {}, invalid = {} }
  if mount == nil then return out end
  for _, name in ipairs(deps.list(mount) or {}) do
    local kind = FILE_KIND[name]
    local path = "/" .. mount .. "/" .. name
    if kind then
      local body = deps.read(path)
      local parsed = body and textutils.unserialise(body) or nil
      if M.validateKind(kind, parsed) then
        out.valid[#out.valid + 1] = kind
      else
        out.invalid[#out.invalid + 1] = path
      end
    else
      out.foreign[#out.foreign + 1] = path
    end
  end
  return out
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS. (Also re-run existing DTC tests — `resolveDeps` now has a `list` default; existing tests that omit `list` still work since `_scanDisk` is the only consumer.)

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/dtc.lua tests/test_bitconfig_dtc.lua
git commit -m "feat(dtc): M._scanDisk classifies disk files valid/invalid/foreign

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task C2: `M._cleanDisk` + `M._scanSummary`

**Files:**
- Modify: `ui/basalt/bitconfig/dtc.lua` (add `M._cleanDisk`, `M._scanSummary` after `M._scanDisk`)
- Test: `tests/test_bitconfig_dtc.lua`

**Interfaces:**
- Consumes: `M._scanDisk` (C1), `deps.delete`.
- Produces: `M._cleanDisk(mount, deps) -> { deleted = {paths…} }` — deletes only `foreign ∪ invalid` (computed via `_scanDisk`), never a valid config; `mount == nil` → empty. `M._scanSummary(scan) -> string` — `"valid N · foreign M · invalid K"`, with `" · CLEAN ADVISED"` appended when `#valid == 0 and (#foreign + #invalid) > 0`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_bitconfig_dtc.lua` (reusing `scanDeps` from C1, extended with delete):
```lua
t.test("_cleanDisk: deletes only foreign+invalid, keeps valid EH2 configs", function()
  local good = textutils.serialise({ gains = {}, caps = {}, feel = {} })
  local byName = { ["eh2_tuning.tbl"] = good, ["eh2_senscal.tbl"] = "bad {{{", ["notes.txt"] = "x" }
  local files = {}
  for name, body in pairs(byName) do files["/disk/" .. name] = body end
  local names = {}; for name in pairs(byName) do names[#names + 1] = name end
  local deps = {
    list   = function(p) return (p == "disk") and names or {} end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    delete = function(p) files[p] = nil end,
  }
  local r = M._cleanDisk("disk", deps)
  t.eq(#r.deleted, 2, "two junk files deleted")
  t.truthy(files["/disk/eh2_tuning.tbl"] ~= nil, "valid config kept")
  t.eq(files["/disk/eh2_senscal.tbl"], nil, "invalid EH2 file deleted")
  t.eq(files["/disk/notes.txt"], nil, "foreign file deleted")
end)

t.test("_cleanDisk: mount=nil -> nothing deleted", function()
  t.eq(#M._cleanDisk(nil, { list = function() return {} end }).deleted, 0)
end)

t.test("_scanSummary: counts and flags clean-advised when only junk present", function()
  t.eq(M._scanSummary({ valid = { "tuning" }, foreign = {}, invalid = {} }), "valid 1 · foreign 0 · invalid 0")
  local s = M._scanSummary({ valid = {}, foreign = { "/disk/x" }, invalid = { "/disk/eh2_senscal.tbl" } })
  t.truthy(s:find("CLEAN ADVISED", 1, true), "clean advised when no valid config but junk present: " .. s)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `M._cleanDisk`/`M._scanSummary` nil.

- [ ] **Step 3: Write minimal implementation**

After `M._scanDisk` add:
```lua
-- ===== M._cleanDisk(mount, deps) -> { deleted={paths…} }: delete ONLY foreign+invalid (never a =====
-- ===== valid EH2 config). Set computed via M._scanDisk so scan and clean can never disagree.
function M._cleanDisk(mount, deps)
  deps = resolveDeps(deps)
  local deleted = {}
  if mount == nil then return { deleted = deleted } end
  local scan = M._scanDisk(mount, deps)
  for _, path in ipairs(scan.foreign) do deps.delete(path); deleted[#deleted + 1] = path end
  for _, path in ipairs(scan.invalid) do deps.delete(path); deleted[#deleted + 1] = path end
  return { deleted = deleted }
end

-- ===== M._scanSummary(scan) -> "valid N · foreign M · invalid K" (+ " · CLEAN ADVISED" when there =====
-- ===== is no valid EH2 config but foreign/invalid junk is present). PURE, display-only.
function M._scanSummary(scan)
  scan = scan or {}
  local nv = #(scan.valid or {})
  local nf = #(scan.foreign or {})
  local ni = #(scan.invalid or {})
  local s = "valid " .. nv .. " \183 foreign " .. nf .. " \183 invalid " .. ni
  if nv == 0 and (nf + ni) > 0 then s = s .. " \183 CLEAN ADVISED" end
  return s
end
```
(`"\183"` is the middle dot `·` in CC's charset; if a test wants the literal `·` byte, keep `\183` and assert with `s:find("valid 1", 1, true)` on the count portion — the C1/C2 tests above match on substrings, not the dot.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/dtc.lua tests/test_bitconfig_dtc.lua
git commit -m "feat(dtc): M._cleanDisk + M._scanSummary (delete only junk, keep configs)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task C3: DTC `SCAN` + `CLEAN` UI (buttons + screens)

**Files:**
- Modify: `ui/basalt/bitconfig/dtc.lua` (`buildTop` SCAN button; add `buildScan` + `buildCleanConfirm`; register screens)
- Test: `tests/test_bitconfig_dtc.lua`

**Interfaces:**
- Consumes: `M._scanDisk`/`M._cleanDisk`/`M._scanSummary` (C1/C2), `configkit`, `drive`/`doDetect`, `dirStatus`.
- Produces: `buildTop` elements gain `scanRow` (1 button: `SCAN`). New screens `"scan"` (`{ summaryLabel, cleanRow, backRow }`) and `"confirm_clean"` (`{ listLabel, confirmRow, backRow }`).

- [ ] **Step 1: Write the failing test**

Add to `tests/test_bitconfig_dtc.lua`:
```lua
t.test("M.build: SCAN screen summarizes disk; CLEAN confirm deletes only junk and pops", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local good = textutils.serialise({ gains = {}, caps = {}, feel = {} })
  local files = {
    ["/disk/eh2_tuning.tbl"] = good, ["/disk/junk.dat"] = "x", ["/disk/eh2_senscal.tbl"] = "bad {{{",
  }
  local fakeDrive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local deps = {
    find = function(k) return k == "drive" and fakeDrive or nil end,
    list = function(p) return (p == "disk") and { "eh2_tuning.tbl", "junk.dat", "eh2_senscal.tbl" } or {} end,
    exists = function(p) return files[p] ~= nil end,
    read = function(p) return files[p] end,
    write = function(p, b) files[p] = b end,
    delete = function(p) files[p] = nil end,
    move = function(a, b) files[b] = files[a]; files[a] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
    backup = function(p) end,
  }
  local h = M.build(basalt, frame, nil, nav, deps)
  local region = h.elements.region
  local top = region.built.top.handle.elements
  t.truthy(top.scanRow ~= nil and #top.scanRow.buttons == 1, "SCAN button present")

  region:push("scan"); h.apply({})
  local sEls = region.built.scan.handle.elements
  t.truthy(sEls.summaryLabel:getText():find("valid 1", 1, true), "scan summary reads valid 1: " .. sEls.summaryLabel:getText())

  region:push("confirm_clean"); h.apply({})
  local cEls = region.built.confirm_clean.handle.elements
  cEls.confirmRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  h.apply({})
  t.truthy(files["/disk/eh2_tuning.tbl"] ~= nil, "valid config kept after CLEAN")
  t.eq(files["/disk/junk.dat"], nil, "foreign deleted")
  t.eq(files["/disk/eh2_senscal.tbl"], nil, "invalid deleted")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `top.scanRow` nil / `scan` screen unbuilt.

- [ ] **Step 3: Write minimal implementation**

In `ui/basalt/bitconfig/dtc.lua`:
1. `buildTop`: add a `scanRow` (after `importAllRow`, before `backRow`), enabled when `drive.present`:
```lua
    local scanRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "SCAN", onClick = function() region:push("scan") end },
    })
    y = y + 1
```
In `refreshTop` add `scanRow.setState(1, drive.present and "off" or "disabled")`, and add `scanRow` to the returned `elements`.
2. Add the two screen builders (near the other builders):
```lua
  local function buildScan(b, f, region)
    local fx, fiw, y = 2, math.max(1, ({ f:getSize() })[1] - 2), 1
    local summaryLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1
    local cleanRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "CLEAN", onClick = function() region:push("confirm_clean") end },
    })
    y = y + 1
    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkit.GLYPH.BACK, onClick = function() region:pop() end },
    })
    local function refresh()
      local scan = M._scanDisk(drive.mount, deps)
      summaryLabel:setText(clampText(M._scanSummary(scan), fiw))
      cleanRow.setState(1, ((#scan.foreign + #scan.invalid) > 0) and "off" or "disabled")
    end
    refresh()
    return { apply = function(_s) refresh() end,
      elements = { summaryLabel = summaryLabel, cleanRow = cleanRow, backRow = backRow } }
  end

  local function buildCleanConfirm(b, f, region)
    local fx, fiw, y = 2, math.max(1, ({ f:getSize() })[1] - 2), 1
    local listLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1
    local confirmRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkit.GLYPH.CONFIRM_OK, onClick = function()
          local r = M._cleanDisk(drive.mount, deps)
          dirStatus.import = "CLEAN: " .. #r.deleted .. " deleted"
          doDetect(); region:pop(); region:apply(nil)
        end },
    })
    y = y + 1
    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkit.GLYPH.CONFIRM_CANCEL, onClick = function() region:pop() end },
    })
    local function refresh()
      local scan = M._scanDisk(drive.mount, deps)
      listLabel:setText(clampText("Delete " .. (#scan.foreign + #scan.invalid) .. " junk file(s)? (configs kept)", fiw))
    end
    refresh()
    return { apply = function(_s) refresh() end,
      elements = { listLabel = listLabel, confirmRow = confirmRow, backRow = backRow } }
  end
```
3. Register both in `screens`:
```lua
  screens.scan = buildScan
  screens.confirm_clean = buildCleanConfirm
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/dtc.lua tests/test_bitconfig_dtc.lua
git commit -m "feat(dtc): SCAN screen + CLEAN confirm (delete only disk junk)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

# Phase Z — Build, register, gate

### Task Z: Register new tests, rebuild dist/manifest, run all gates

**Files:**
- Modify: `tests/run_headless.sh`, `tests/run_headless_dist.sh` (add `tests.test_fcs2disk`)
- Regenerate: `manifest*.lua`, `dist/**` via the build pipeline

**Interfaces:**
- Consumes: everything above. This is the only task that touches manifest/dist.

- [ ] **Step 1: Register the new test suite in both runners**

Confirm `tests.test_fcs2disk` is in the `suites` list in BOTH `tests/run_headless.sh` (added in B1) and `tests/run_headless_dist.sh` — add it to `run_headless_dist.sh` if absent. (`test_configkit`, `test_bitconfig_mdb`, `test_bitconfig_dtc`, `test_suitex`, `test_manifest_tools` are already registered.)

- [ ] **Step 2: Rebuild the dist + manifest**

Run:
```bash
node tools/build.mjs && bash tools/run_gen.sh
```
Expected: `dist/**` and `manifest*.lua` regenerate; `fcs2disk` now appears in the built manifest `tools` + dist closure.

- [ ] **Step 3: Run all three gates**

Run:
```bash
bash tests/run_headless.sh && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh
```
Expected: all three green. If the dist gate flags a sync-guard mismatch, re-run Step 2 (the build) and re-stage.

- [ ] **Step 4: Commit the build artifacts**

```bash
git add tests/run_headless.sh tests/run_headless_dist.sh manifest*.lua dist
git commit -m "build: register fcs2disk test + rebuild dist/manifest for config UX tweaks

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: Whole-branch review + ship**

- Whole-branch review (opus, source-only) per `superpowers:requesting-code-review`.
- Address findings via `superpowers:receiving-code-review`.
- `superpowers:finishing-a-development-branch`: ff-merge to `main` → `git push origin main`.
- Update the `eh2-config-overhaul-checkpoint` sibling memory; delete `HANDOFF-config-ux-tweaks-2026-08-16.md`.

---

## Self-review notes (author)

- **Spec coverage:** Feature 1 → A1–A3 (constants, MDB footer, DTC top). Feature 2 → B1–B6 (tool core, run+launcher, SuiteX, manifest, `_importAll`, IMPORT ALL UI). Feature 3 → C1–C3 (`_scanDisk`, `_cleanDisk`+`_scanSummary`, SCAN/CLEAN UI). Build/gates → Z. Glyph caveat honored via `configkit.GLYPH` word-fallbacks (A1) confirmed in-game at ship. No frozen flight code touched.
- **In-game verify (user, at ship):** buttons readable/spaced on the real monitors (confirm any glyph renders before flipping a `GLYPH` constant); run `fcs2disk` on the FCS → 3 configs appear on the shared disk → UI DTC `IMPORT ALL` pulls them; drop a junk file on a disk → DTC `SCAN` flags it → `CLEAN` (confirm) removes only the junk, keeps valid configs.
- **Open verification for implementers:** B3 (SuiteX checkbox construction) and B4 (manifest test helper name) must be matched to the exact surrounding code — read lines ~700-740 of `easyhover2_suitex.lua` and the `splitconfig` case in `tests/test_manifest_tools.lua` before editing. B2's launcher should mirror `launchers/splitconfig.lua`'s exact idiom.
