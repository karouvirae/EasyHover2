# SuiteX dev-channel toggle — design

**Date:** 2026-08-11
**Project:** EasyHover 2
**Status:** Approved (brainstorming complete)

## Problem

The minify build step (shipped `d0062db`) gave the classic `easyhover2_suite.lua` a
two-channel install: minified by default, readable source via `--dev`, persisted in
`/eh2_channel.txt`. **SuiteX** (the Basalt 2.0 front-end, `easyhover2_suitex.lua`) was
not part of that work — it fetches `manifest.lua` hardcoded (`easyhover2_suitex.lua:597`)
and has **no channel awareness**:

- It always installs the minified channel (correct as a default, but the readable dev
  channel is unreachable through the graphical Suite).
- It ignores `/eh2_channel.txt`: a user who set `dev` via the classic suite's `--dev`,
  then runs SuiteX, gets a minified reinstall — and SuiteX never updates the marker, so a
  later bare classic run flips back to dev (channel ping-pong when the two suites are
  mixed).

SuiteX's install/replace/repair themselves are already correct: Go and Repair delegate to
the shared `Suite.performPlan` (`:514`, `:525`), so the in-place delete-then-write engine,
config-sacred `guard()`, and repair-clears-then-reinstalls all apply unchanged. Only the
**channel selection** is missing.

## Goal

Give SuiteX a **"Dev version" checkbox in its Advanced tab** — the graphical equivalent of
the classic suite's `--dev`. Ticked, the main-menu actions (Go / Repair / role Switch)
install the readable dev channel; unticked, the minified default. Ticking re-checks the
dashboard against the selected channel; the persisted marker changes only on an actual
install. Booting SuiteX honors an existing `/eh2_channel.txt`, closing the ignore-the-marker
gap.

## Decisions (locked in brainstorming)

1. **Persist on install, not on toggle.** Ticking re-fetches/re-checks against the dev
   manifest (inspection only, no marker write). The marker `/eh2_channel.txt` is written to
   the selected channel **after a successful `performPlan`** (Go / Repair / Switch) —
   mirroring the classic rule the minify work hardened: `--check`/`--list` inspect without
   persisting; a real `--dev` install persists.
2. **Manifest loading = lazy-fetch + cache (approach A).** Boot fetches only the active
   channel's manifest. The first toggle to the other channel fetches it and caches it in
   `ctx.manifests[channel]`; later toggles are instant in-memory swaps. A fetch failure on
   toggle (e.g. an older server without `manifest-dev.lua`) logs the error, reverts the
   checkbox and `ctx.channel`, and keeps the current channel.
3. **Element = Basalt `CheckBox`** (confirmed present in the pinned `release/basalt-full.lua`
   build). Placed in `ui.frameAdv`, replacing the current `:506` "Advanced tools — coming
   soon." placeholder.
4. **Scope = the whole graphical install path.** Go, Repair, and role Switch all install the
   selected channel — they already route through `performPlan(ctx.Suite.base, ctx.manifest,
   ctx.spec, …)`, so swapping `ctx.manifest`/`ctx.spec` to the selected channel is sufficient;
   no per-action change.
5. **The install engine is untouched.** `performPlan`, `guard()`, delete-then-write, verify,
   and repair are not modified. This feature only changes *which manifest* SuiteX loads and
   *which channel marker* it stamps.
6. **YAGNI:** a two-state dev/min checkbox only. No tri-state, no per-role channels, no UI to
   edit the marker beyond the box.

## Architecture

Three touch-points in `easyhover2_suitex.lua`, plus one new helper.

### 1. Channel state + marker-honoring boot

- Add `ctx.channel` ("min" | "dev"), initialized from the marker:
  `ctx.channel = Suite.resolveChannel(nil, Suite.readFile(Suite.CHANNEL_FILE))`
  (`resolveChannel`, `manifestName`, `CHANNEL_FILE` are already exposed on `Suite` by the
  minify work; `readFile` is already exposed to SuiteX.)
- The boot manifest fetch (`:597`) becomes:
  `Suite.fetch(Suite.base .. "/" .. Suite.manifestName(ctx.channel))`.
- Cache the fetched manifest: `ctx.manifests = { [ctx.channel] = manifest }`.

### 2. `reloadManifest(ctx, channel)` — swap channel, re-check

A new local function that:
1. If `ctx.manifests[channel]` is cached, use it; else `Suite.fetch(base .. "/" ..
   Suite.manifestName(channel))`, unserialise, validate (`type(manifest.roles)=="table"` and
   `manifest.version`), and cache it. On fetch/parse failure: return `false, err` (caller
   reverts).
2. On success: set `ctx.channel = channel`, `ctx.manifest = manifest`, rebuild `ctx.order =
   buildOrder(manifest)` and the role-dropdown items, refresh the subtitle release version,
   re-resolve `ctx.spec = manifest.roles[ctx.role]` for the currently-selected role (if any),
   and call `startCheck(ctx)` so the dashboard reflects the new channel's plan. Return `true`.

Basalt/glue notes: guard the toggle with `ctx.opInFlight` (no channel switch mid-install,
same discipline as the theme toggle); the checkbox's change handler calls `reloadManifest`
and, on failure, restores the checkbox's checked state to match the unchanged `ctx.channel`
and logs via `logLine`.

### 3. Persist the marker on install

In `runEngineOp`'s coroutine tail (after a successful `pcall(fn)` that ran `performPlan`),
write the marker to the installed channel:
`local f = fs.open(Suite.CHANNEL_FILE, "w"); if f then f.write(ctx.channel .. "\n"); f.close() end`
Only on success (the `ok` branch) — a failed/interrupted install must not restamp the channel,
consistent with the classic suite writing the marker on a real run. Writing directly is
equivalent to the classic `writeRaw(CHANNEL_FILE, channel.."\n")`; `PROTECTED` gates only the
release install/delete path, never SuiteX's own marker write.

### 4. The Advanced-tab checkbox

Replace the `:506` placeholder label with a `CheckBox` in `ui.frameAdv`:
- Label: `Dev version (readable source)`.
- Initial checked state = `(ctx.channel == "dev")`.
- On change: if `ctx.opInFlight`, immediately revert the box to `ctx.channel` and return
  (no-op mid-install); else call `reloadManifest(ctx, checked and "dev" or "min")`, reverting
  the box on failure.
- Repainted by `applyTheme` alongside the other Advanced-tab elements (palette-aware).

## Data flow

```
boot: read /eh2_channel.txt -> ctx.channel (min|dev)
      fetch manifest<channel>.lua -> ctx.manifest, cache in ctx.manifests[channel]
      checkbox checked = (channel=="dev")

tick/untick (not opInFlight):
      reloadManifest(ctx, dev|min)
        cached? swap : fetch+validate+cache   -- fail -> revert box + log, keep channel
        rebuild manifest/order/dropdown/subtitle/spec ; startCheck  (inspect only, NO marker write)

Go / Repair / Switch:
      performPlan(base, ctx.manifest<selected channel>, ctx.spec, role, plan, fresh)   -- unchanged engine
      on success: write /eh2_channel.txt = ctx.channel
```

## Error handling

- **Toggle fetch/parse failure** (missing/corrupt `manifest-dev.lua`): `reloadManifest` returns
  `false, err`; the handler logs "could not load the dev channel: …", reverts the checkbox and
  leaves `ctx.channel`/`ctx.manifest` unchanged. The dashboard keeps showing the current channel.
- **Install failure:** `runEngineOp` already logs the failure; the marker is written only on the
  success path, so a failed dev install does not stamp `dev`.
- **Toggle during an op:** guarded by `ctx.opInFlight` — the box reverts and the toggle is a no-op.
- **No role selected yet:** `reloadManifest` still swaps the manifest and rebuilds the dropdown;
  `startCheck` early-returns on `not ctx.spec` (existing behavior), so the channel is armed for
  when a role is picked.

## Testing

- **Reuse existing unit coverage:** `Suite.resolveChannel` / `Suite.manifestName` are already
  unit-tested in `tests/test_suite.lua`; SuiteX consumes them, so channel resolution and
  manifest-name mapping need no new tests.
- **New pure helper, if any:** if a pure helper is extracted (e.g. a checkbox-label or
  channel→checked mapping), add a `tests/test_suitex.lua` unit test for it, matching how
  SuiteX's other pure helpers are tested.
- **Glue is read-verified + in-game**, consistent with the rest of SuiteX (`reloadManifest`,
  the toggle handler, and the marker write are Basalt-glue, untested-by-design headlessly).
- **Regression safety net:** the full headless suite (`run_headless.sh` + `run_headless_dist.sh`)
  must stay green (SuiteX changes must not break `test_suitex.lua` or the manifest-sync guard),
  and `run_gen.sh --check` must stay IN SYNC after any regeneration.
- **In-game acceptance (user):** with a current server (both manifests present) — tick Dev,
  confirm the dashboard flips to an update/repair plan, Go installs readable source, and
  `/eh2_channel.txt` reads `dev`; untick, Go installs minified, marker reads `min`; reboot SuiteX
  and confirm the box boots pre-ticked to match the marker; confirm a config survives a
  channel-switch install.

## Out of scope

- Changing `performPlan`, `guard`, verification, or repair (unchanged).
- Any classic-suite change (the classic `--dev`/`--min` flow is already shipped).
- A tri-state or per-role channel selector; a UI to hand-edit the marker.
- Headless end-to-end testing of SuiteX's Basalt render/event loop (unchanged limitation).

## Files touched

- `easyhover2_suitex.lua` — `ctx.channel` + marker-honoring boot fetch; `reloadManifest`; the
  Advanced-tab `CheckBox`; marker write in `runEngineOp`.
- `tests/test_suitex.lua` — a unit test only if a new pure helper is extracted.
- No `manifest*.lua` / `dist/` change (this feature ships no new role files; regenerate the
  manifest only if the suite's own bytes change, which restamps `updater` in both manifests as
  usual).
