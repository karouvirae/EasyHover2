# SuiteX dev-channel toggle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Dev version" checkbox to SuiteX's Advanced tab — the graphical equivalent of the classic suite's `--dev` — so the graphical installer can install the readable source channel, honor an existing `/eh2_channel.txt` on boot, and stamp the marker on install.

**Architecture:** Two touch-point groups in `easyhover2_suitex.lua`. (1) A channel-aware core: `ctx.channel` initialized from the marker, the boot manifest fetch keyed on `Suite.manifestName(channel)`, a cached `reloadManifest(ctx, channel)` helper, and a marker write on a successful install. (2) A Basalt `CheckBox` in the Advanced tab whose toggle drives `reloadManifest`. The shared `Suite.performPlan` install/guard/verify/repair engine is untouched — only *which manifest* SuiteX loads and *which marker* it stamps change.

**Tech Stack:** Lua 5.1 (CC:Tweaked); Basalt 2.0 full build (vendored `release/basalt-full.lua`, pinned f6cde73); CraftOS-PC headless for the regression suite.

## Global Constraints

Every task's requirements implicitly include these:

- **Install engine UNCHANGED.** Do not modify `Suite.performPlan`, `guard()`, verification, staging, or repair. This feature changes only manifest selection and the channel-marker write inside SuiteX.
- **Persist on install, not on toggle.** Toggling the checkbox re-checks against the selected channel (inspection); `/eh2_channel.txt` is written only after a *successful* `performPlan` (Go/Repair), never on a toggle/inspection — mirroring the classic `--check`/`--list`-don't-persist rule.
- **Reuse the already-exposed engine surface:** `Suite.resolveChannel(flag, markerRaw)`, `Suite.manifestName(channel)`, `Suite.CHANNEL_FILE`, `Suite.readFile`, `Suite.fetch`, `Suite.base`, `Suite.isReleased`, `Suite.checksum` (all on the `Suite` table; SuiteX already consumes `readFile`/`parseState`/`STATE_FILE`).
- **Basalt CheckBox API** (verified vs pinned source): create with `frame:addCheckBox({ checked=<bool>, text=" ", checkedText="x", … })`; read/write the state via `el:get("checked")` / `el:set("checked", v)`; register the handler with `el:onChange("checked", function(self, checked) … end)`. The `onChange` observer **fires on programmatic `set()` as well as user clicks** — guard reverts with a suppress flag to avoid recursion.
- **No manifest/`dist` change:** `easyhover2_suitex.lua` is a standalone `wget run` program — it is NOT in any role's `require()` closure and is NOT the `updater` entry (that's `easyhover2_suite.lua`), so editing it does not change `manifest.lua`/`manifest-dev.lua`. `run_gen.sh --check` stays IN SYNC with no regeneration.
- **YAGNI:** a two-state dev/min checkbox only. No tri-state, no per-role channels, no marker-editing UI.

## File Structure

- `easyhover2_suitex.lua` — **modify**. All feature changes: boot channel init + manifest fetch (`SuiteX.run`, ~L596-665), `reloadManifest` helper (new local, after `activateRole` ~L390), marker write (`runEngineOp` ~L406-421), the Advanced-tab checkbox + `applyTheme` repaint (`buildUI` ~L506, `applyTheme` ~L285-291).
- `tests/test_suitex.lua` — **modify only if** a new *pure* helper is extracted (not expected; the new code is Basalt glue + network, consistent with SuiteX's existing untested-by-design glue).

## Verification model (read this — the feature is Basalt glue)

Most of this feature is UI/network glue that SuiteX does not unit-test headlessly (its `test_suitex.lua` covers pure helpers only). So each task's gate is: (a) the **full headless suite stays green** — `bash tests/run_headless.sh` → `OK` (no regression in `test_suitex.lua` or elsewhere) and `bash tools/run_gen.sh --check` → `IN SYNC`; (b) **read-verification** of the specific properties each task lists; (c) a **CraftOS smoke** where noted (the Basalt add-method exists / loads); and (d) **in-game acceptance** by the user at the end. Do not fabricate headless coverage for Basalt render/event behavior.

---

## Task 1: Channel-aware core (boot honors marker, reloadManifest, persist-on-install)

**Files:**
- Modify: `easyhover2_suitex.lua` (`SuiteX.run` boot fetch + `ctx`; new `reloadManifest`; `runEngineOp` marker write)

**Interfaces:**
- Produces: `ctx.channel` ("min"|"dev"); `ctx.manifests` = `{ [channel] = manifest }` cache; `reloadManifest(ctx, channel) -> true | false,err` (a file-local function, defined after `activateRole` and before `buildUI`, that swaps to a channel's manifest — cached after first fetch — rebuilds `ctx.manifest`/`ctx.order`/`ctx.spec` + the subtitle and role dropdown, and calls `startCheck`; it does NOT write the marker). Task 2 consumes `reloadManifest` and `ctx.channel`.

- [ ] **Step 1: Boot resolves the channel from the marker and fetches the matching manifest**

In `SuiteX.run`, replace the hardcoded manifest fetch (currently `easyhover2_suitex.lua:597`):
```lua
  -- ---- the release channel (honors /eh2_channel.txt, same marker the classic suite uses) + manifest
  local channel = Suite.resolveChannel(nil, Suite.readFile(Suite.CHANNEL_FILE))
  local manifestBody, manifestErr = Suite.fetch(Suite.base .. "/" .. Suite.manifestName(channel))
  if not manifestBody then
    abort("could not fetch the release manifest: " .. tostring(manifestErr))
    return
  end
```
(The `unserialise` + validation block immediately below stays unchanged.)

- [ ] **Step 2: Seed the channel + manifest cache into `ctx`**

In the `ctx` table literal (currently `easyhover2_suitex.lua:660-665`), add two fields:
```lua
  local ctx = {
    mode = "dark", pal = SuiteX.theme.get("dark"),
    Suite = Suite, basalt = basalt, manifest = manifest, order = buildOrder(manifest),
    role = role, spec = spec, state = state, hasFiles = hasFiles, tab = "main",
    plan = nil, report = nil, diffLabel = nil, checkDone = false, opInFlight = false,
    channel = channel, manifests = { [channel] = manifest },
  }
```

- [ ] **Step 3: Add the `reloadManifest` helper**

Insert a new file-local function immediately after `activateRole` (which ends ~`easyhover2_suitex.lua:390`) so it can see `buildOrder`, `activateRole`, and `startCheck`:
```lua
--- Swap SuiteX to another release channel: load that channel's manifest (cached in ctx.manifests
--- after the first fetch), rebuild the manifest-derived UI + the current role's spec, and re-arm
--- the check so the dashboard reflects the new channel's plan. INSPECTION ONLY -- never writes the
--- /eh2_channel.txt marker (that happens on a real install, in runEngineOp). Returns true, or
--- false+err on a fetch/parse failure so the caller can revert the checkbox and keep the current
--- channel.
local function reloadManifest(ctx, channel)
  local manifest = ctx.manifests[channel]
  if not manifest then
    local body, err = ctx.Suite.fetch(ctx.Suite.base .. "/" .. ctx.Suite.manifestName(channel))
    if not body then return false, err end
    manifest = textutils.unserialise(body)
    if type(manifest) ~= "table" or type(manifest.roles) ~= "table" or not manifest.version then
      return false, "the " .. channel .. " manifest is not readable"
    end
    ctx.manifests[channel] = manifest
  end
  ctx.channel = channel
  ctx.manifest = manifest
  ctx.order = buildOrder(manifest)
  -- keep the same role if the new channel still ships it; otherwise fall back to "unresolved"
  if ctx.role and manifest.roles[ctx.role] and ctx.Suite.isReleased(manifest.roles[ctx.role]) then
    ctx.spec = manifest.roles[ctx.role]
  else
    ctx.role, ctx.spec = nil, nil
  end
  -- refresh the manifest-derived UI (version subtitle + role dropdown items)
  ctx.ui.subtitle:setText("release " .. tostring(manifest.version or "?"))
  local roleItems = {}
  for _, name in ipairs(ctx.order) do
    if ctx.Suite.isReleased(manifest.roles[name]) then
      roleItems[#roleItems + 1] = { text = name, callback = function() activateRole(ctx, name) end }
    end
  end
  ctx.ui.roleDropdown:setItems(roleItems)
  ctx.ui.roleDropdown:setSelectedText(ctx.role or "(choose)")
  startCheck(ctx)   -- early-returns cleanly if ctx.spec is nil
  return true
end
```

- [ ] **Step 4: Persist the marker on a successful install**

In `runEngineOp`'s coroutine tail (currently `easyhover2_suitex.lua:412-417`), write the channel marker only on the success branch:
```lua
    local ok, err = pcall(fn)
    ctx.Suite.sink = nil
    ctx.opInFlight = false
    if not ok then
      logLine(ctx, "action failed: " .. tostring(err), ctx.pal.error)
    else
      -- Persist the channel actually installed so a later bare classic run stays on it (mirrors
      -- the classic suite writing /eh2_channel.txt on a real --dev/--min install). PROTECTED gates
      -- only the release install/delete path, never the Suite's own marker write.
      local f = fs.open(ctx.Suite.CHANNEL_FILE, "w")
      if f then f.write(ctx.channel .. "\n"); f.close() end
    end
    ctx.state = ctx.Suite.parseState(ctx.Suite.readFile(ctx.Suite.STATE_FILE))
    ctx.hasFiles = fs.exists("/startup.lua")
    startCheck(ctx)
```

- [ ] **Step 5: Regression + read-verify**

Run: `bash tests/run_headless.sh` (must print `OK`, `test_suitex.lua` green) and `bash tools/run_gen.sh --check` (must print `IN SYNC` — suitex isn't in the manifest, so no regen needed).
Read-verify and state in the report: (a) the boot fetch now uses `Suite.manifestName(channel)` and a `dev` marker makes it fetch `manifest-dev.lua`; (b) `reloadManifest` writes NO marker and reverts cleanly on a fetch/parse failure (returns `false,err`); (c) the marker write sits ONLY on `runEngineOp`'s success branch (never on failure, never in `startCheck`/`verify`); (d) `performPlan`/`guard` are untouched (grep the diff — no hunk in the install/guard region).

- [ ] **Step 6: Commit**

```bash
git add easyhover2_suitex.lua
git commit -m "$(cat <<'EOF'
feat(suitex): channel-aware core -- honor /eh2_channel.txt, stamp it on install

SuiteX resolves the release channel from /eh2_channel.txt on boot (via the
exposed Suite.resolveChannel/manifestName) and fetches the matching manifest, so
it now honors an existing dev marker instead of always installing minified. Adds
reloadManifest(ctx,channel) (cached per channel) to swap channels + re-check, and
writes the marker on a successful install only -- mirroring the classic suite.
The performPlan install/guard/verify/repair engine is untouched.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Advanced-tab "Dev version" checkbox

**Files:**
- Modify: `easyhover2_suitex.lua` (`buildUI` Advanced-tab content ~L506; `applyTheme` repaint ~L285-291)

**Interfaces:**
- Consumes: `reloadManifest(ctx, channel)` and `ctx.channel` from Task 1.
- Produces: `ctx.ui.devCheck` (the Basalt CheckBox), `ctx.ui.devCheckLabel`, and the Advanced-tab channel label; a `ctx.suppressDevBox` flag guarding programmatic reverts.

- [ ] **Step 1: Confirm the Basalt add-method + change signature against the vendored build**

Before wiring, verify (grep `release/basalt-full.lua` and/or a tiny CraftOS-PC smoke) that `frame:addCheckBox` is the correct method name (vs `addCheckbox`) and that `:onChange("checked", fn)` is accepted on the returned element. Record the confirmed names in the report. If the method is spelled differently in this pinned build, use the actual spelling throughout.

- [ ] **Step 2: Replace the Advanced-tab placeholder with the checkbox**

Replace the placeholder label (currently `easyhover2_suitex.lua:506`):
```lua
  -- Advanced tab: the dev-channel toggle -- graphical equivalent of the classic suite's --dev.
  -- Ticked installs the readable source channel (manifest-dev.lua); unticked the minified default.
  -- The choice re-checks the dashboard immediately; it is persisted to /eh2_channel.txt only on a
  -- real install (runEngineOp), never on the toggle itself.
  ui.advancedLabel = ui.frameAdv:addLabel({ x = 2, y = 2, text = "Install channel", foreground = pal.dim })
  ui.devCheck = ui.frameAdv:addCheckBox({ x = 2, y = 3, checked = (ctx.channel == "dev"),
    text = " ", checkedText = "x", background = pal.bg, foreground = pal.text })
  ui.devCheckLabel = ui.frameAdv:addLabel({ x = 6, y = 3,
    text = "Dev version (readable source)", foreground = pal.text })
  ui.devCheck:onChange("checked", function(_, checked)
    if ctx.suppressDevBox then return end               -- ignore our own programmatic reverts
    local desired = checked and "dev" or "min"
    if desired == ctx.channel then return end            -- idempotent (also absorbs a revert-to-same)
    if ctx.opInFlight then                                -- no channel switch mid-install
      ctx.suppressDevBox = true
      ui.devCheck:set("checked", ctx.channel == "dev")
      ctx.suppressDevBox = false
      return
    end
    local okReload, err = reloadManifest(ctx, desired)
    if not okReload then
      logLine(ctx, "could not load the " .. desired .. " channel: " .. tostring(err), ctx.pal.error)
      ctx.suppressDevBox = true
      ui.devCheck:set("checked", ctx.channel == "dev")   -- revert to the channel still in effect
      ctx.suppressDevBox = false
    end
  end)
```
Note: `checked` is set at construction BEFORE `onChange` is registered, so the initial state fires no handler; only user clicks and our guarded reverts do.

- [ ] **Step 3: Repaint the new Advanced-tab elements in `applyTheme`**

In `applyTheme` (currently repaints `ui.advancedLabel` ~`easyhover2_suitex.lua:290`), repaint the new elements so a theme toggle keeps them palette-correct:
```lua
  ui.advancedLabel:setForeground(pal.dim)
  ui.devCheck:setBackground(pal.bg); ui.devCheck:setForeground(pal.text)
  ui.devCheckLabel:setForeground(pal.text)
```
(Match the exact setter style used by the surrounding `applyTheme` lines.)

- [ ] **Step 4: Regression + read-verify**

Run: `bash tests/run_headless.sh` → `OK`; `bash tools/run_gen.sh --check` → `IN SYNC`.
Read-verify and state in the report: (a) toggling calls `reloadManifest` and, on failure, reverts the box via the `suppressDevBox` guard (no recursion, no marker write); (b) a toggle while `ctx.opInFlight` is a guarded no-op that restores the box; (c) the box boots checked iff `ctx.channel == "dev"`; (d) `applyTheme` repaints the new elements. If CraftOS-PC can load SuiteX headlessly far enough to construct the frame (it needs a colour term — may not), note whether a smoke was possible; otherwise rely on read-verification + the in-game gate.

- [ ] **Step 5: Commit**

```bash
git add easyhover2_suitex.lua
git commit -m "$(cat <<'EOF'
feat(suitex): Dev version checkbox in the Advanced tab

Advanced-tab CheckBox toggles the install channel: ticked = readable dev source
(manifest-dev.lua), unticked = minified default -- the graphical --dev. Toggling
re-checks the dashboard against the channel (reloadManifest); a fetch failure or a
mid-install toggle reverts the box via a suppress guard (no recursion, no marker
write). applyTheme repaints it. The marker persists on install only (Task 1).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Boot honors `/eh2_channel.txt` (spec §Architecture 1) → Task 1 Steps 1-2. ✅
- `reloadManifest` lazy-fetch + cache, revert on failure (§2, Decision 2) → Task 1 Step 3. ✅
- Persist on install only (§3, Decision 1) → Task 1 Step 4. ✅
- Advanced-tab CheckBox, opInFlight guard, revert-on-failure, applyTheme repaint (§4) → Task 2. ✅
- Install engine untouched (Decision 5) → Global Constraints + read-verify in both tasks. ✅
- Scope = Go/Repair/Switch via unchanged `performPlan` on the swapped `ctx.manifest` (Decision 4) → inherent (Go/Repair/Switch already use `ctx.manifest`/`ctx.spec`, which `reloadManifest` swaps). ✅
- Error handling: toggle fetch/parse failure reverts (Task 2 Step 2), install failure doesn't stamp (Task 1 Step 4), toggle-during-op guarded (Task 2 Step 2), no-role swap (reloadManifest nulls spec, startCheck early-returns). ✅
- Testing model (spec §Testing) → the "Verification model" section + each task's regression+read-verify step. ✅

**Placeholder scan:** none — all code is concrete. The only deliberate open item is confirming `addCheckBox` spelling against the vendored build (Task 2 Step 1), which is a verification step, not a placeholder.

**Type/name consistency:** `reloadManifest(ctx, channel) -> true|false,err` defined in Task 1 Step 3 and consumed in Task 2 Step 2; `ctx.channel`, `ctx.manifests`, `ctx.suppressDevBox`, `ctx.ui.devCheck`/`devCheckLabel`/`advancedLabel` used consistently. Reuses `buildOrder`, `activateRole`, `startCheck`, `logLine`, `Suite.manifestName`/`resolveChannel`/`CHANNEL_FILE`/`isReleased`/`fetch`/`base`/`readFile` — all pre-existing.

**Ordering:** `reloadManifest` is defined after `activateRole` (uses it) and before `buildUI` (the checkbox calls it) — correct Lua local-before-use ordering. Task 1 is independently valuable (SuiteX honors the marker + stamps on install even before the checkbox exists); Task 2 adds the interactive toggle on top.
