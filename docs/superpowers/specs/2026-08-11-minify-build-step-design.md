# Pre-deploy minify build step — design

**Date:** 2026-08-11
**Project:** EasyHover 2
**Status:** Approved (brainstorming complete), **NOT started** — recorded-state handoff. Diagnosis corrected below after discovering a concurrent session's change.

## ⚠️ CONCURRENCY / CORRECTION (read first)

This spec was drafted believing the `ui`-role >1 MB overflow was caused by the
suite's **2× `.eh2new` staging peak** at update time. That is **no longer true for
current HEAD.** A **concurrent session** landed commit **`d7be6de` (2026-08-11):
"install files in place, one at a time"** — `Suite.performPlan` now deletes-then-writes
each verified file directly (`easyhover2_suite.lua:594`), so the peak is **one file of
headroom, not 2×**. That change *was* the fix for the disk-full. **Reconcile this spec
with the other session's handoff before implementing.**

**Corrected picture (measured from the manifest, current HEAD):**
- `ui` role steady state = **612 KB** (basalt 306 KB, already vendor-minified + pinned =
  irreducible floor; + ~306 KB UI app code). `fcs` role = 106 KB.
- With in-place install the `ui` role **no longer overflows** on install — but it sits at
  **61 % of a 1 MB disk**, leaving thin headroom for configs, the rolling backup, DTC
  disk exports, the suite itself, and logs.

So minify is now a **headroom improvement, not a crash fix.**

## Problem (corrected)

The `ui` (cockpit) role occupies **612 KB — 61 % of the default 1 MB disk** — of which
**half (306 KB) is basalt**, which cannot shrink (vendor-minified `full` build, pinned by
the `feedback-basalt-full-build` house rule). That leaves little margin for runtime data.

## Goal

Reclaim disk headroom on the `ui` computer by cutting the **byte** footprint of the app
source (basalt untouched), via a **pre-deploy build step** that minifies the deployable
files with **luamin** (https://mths.be/luamin). Target: `ui` role **612 KB → ~437 KB**,
free space ~388 KB → **~563 KB**.

## Evidence (measured, not estimated)

Ran `luamin.minify` over the whole app tree (`fcs/ ui/ launchers/ tools/`, 89 files)
on this machine (Node v22, luamin 1.0.4):

- **All 89 files parsed** — zero CC:Tweaked-dialect failures. No parse gate needed
  beyond "fail the build if a file ever stops parsing".
- **57.1 % reduction** on the full app tree: 340 KB → 146 KB, ~190 KB saved.
- Applied to the `ui` role specifically: its **~306 KB of app code → ~131 KB**, so the
  `ui` role drops **612 KB → ~437 KB** (basalt's 306 KB is untouched). Free space on a
  1 MB disk: ~388 KB → **~563 KB**.

## Decisions (locked during brainstorming)

1. **Goal = disk quota** (byte reduction). Not request-count, not load-time.
2. **Tool = luamin**, called via its **Node API** (`require('luamin').minify(src)`),
   not the finicky CLI. luamin is parser-based (luaparse), scope-aware: renames
   **locals only**, never globals or table-field names, and preserves
   table-constructor order — so `peripheral.*`/`redstone.*` stay intact and
   `textutils.serialise` key-order parity (see memory `reference-cct-serialise-order`)
   still holds.
3. **Shape = per-file minify** into a `dist/` tree mirroring source. NOT a
   single-file bundle. The `require()` graph, manifest, per-file checksums and
   `.eh2new` staging all keep working unchanged.
4. **Keep a readable dev channel** — the suite can install minified (default) or
   readable source, so an in-game FCS fault can be diagnosed with line-accurate,
   real-named code.
5. **Commit `dist/`** into the repo (like `manifest.lua` is generated-and-committed
   today) — GitHub raw only serves committed files and the suite fetches over raw
   URLs; this keeps the `wget run` model intact.
6. **Default channel = minified** — a bare `wget run … suite` install is minified;
   `--dev` is the escape hatch.

## Scope of minification

- **Minify:** every `.lua` under `fcs/`, `ui/`, `launchers/`, `tools/` → `dist/<same path>`.
- **Do NOT minify — referenced from their original paths, identical in both channels:**
  - `release/basalt-full.lua` — already the vendor's minified build, pinned by the
    `feedback-basalt-full-build` house rule; re-minifying a 306 KB third-party file
    gains little and risks much.
  - `manifest.lua` / `manifest-dev.lua` — data parsed by `textutils.unserialise`,
    meant to stay human-diffable.
  - `easyhover2_suite.lua` / `easyhover2_suitex.lua` — the `wget run` bootstrap /
    trust root; keep readable, and they are not part of a role's quota-bearing
    closure.

## Architecture

### 1. Build tool — `tools/build.mjs` (Node + luamin)

- Walk the four app dirs; `luamin.minify` each `.lua`; write to `dist/<path>`.
- **Hard-fail the whole build** if any file fails to parse (dialect gate); write
  nothing partial.
- Copy-through nothing else (basalt/manifests/suite stay at their original paths).
- Deterministic and idempotent: re-running with unchanged source yields byte-identical
  `dist/`.
- Parameterise the minify-dir list and copy-through list as top-of-file config so the
  same script vendors cleanly into other projects later.

### 2. Two-channel manifest model — extend `tools/gen_manifest.lua`

Role membership is the `require()` closure of each role's launchers
(`tools/closure.lua`) — **channel-independent**, computed once from source. Then emit
**two** manifests:

- `manifest.lua` — **default / minified**: each file entry's `src` → `dist/…`,
  `sum`/`size` computed over the **minified** bytes.
- `manifest-dev.lua` — **readable**: `src` → root source path, `sum`/`size` over
  **source** bytes.

`dst` names and role structure are identical across both; the basalt entry is
identical (points at `release/basalt-full.lua`). Each manifest keeps its own `version`
digest over its own channel's bytes. Because `dst` names match, a channel switch is a
`--repair`.

`--check` mode must validate **both** manifests are in sync with what the current
source (+ built `dist/`) would produce.

### 3. Dev-channel escape hatch — `easyhover2_suite.lua`

- `--dev` fetches `manifest-dev.lua`; default fetches `manifest.lua`.
- Persist the choice in a marker file (e.g. `/eh2_channel.txt` = `min`|`dev`) so
  later bare updates stay on the chosen channel.
- `--min` forces back to minified. Switching channel is a repair (same `dst` names,
  different bytes) — the existing staging/commit/guard path handles it; **config files
  remain sacred** (protected-list untouched), per the suite's existing guarantees.
- Everything else (checksum-per-file, all-or-nothing staging, config extend) is
  unchanged.

### 4. Acceptance gate — `tests/run_headless_dist.sh`

A variant of `tests/run_headless.sh` that copies **`dist/`** role dirs into the
CraftOS computer root instead of the source dirs (tests under `tests/` stay as source
and `require` the modules, so they exercise the **minified** code). The full suite
must print `OK`. This is the proof luamin preserved behaviour — required before any
release. Keep the existing `run_headless.sh` (source) as the fast inner-loop runner.

### 5. Release workflow (updates memory `feedback-lua-project-release-workflow`)

```
node tools/build.mjs           # source -> dist/ (minified), hard-fail on parse error
bash tools/run_gen.sh          # regen BOTH manifest.lua + manifest-dev.lua
bash tests/run_headless.sh     # fast: suite against source
bash tests/run_headless_dist.sh# gate: suite against minified dist/  -> must be OK
git add -A && git commit …     # source + dist/ + both manifests
git push origin main
```

## Data flow

```
source (.lua, readable)
   │  tools/build.mjs (luamin)
   ▼
dist/ (.lua, minified)  ──┐
release/basalt-full.lua ──┼─► tools/gen_manifest.lua ─► manifest.lua      (min, default)
source (.lua, readable) ──┘                          └─► manifest-dev.lua  (readable)
                                                                │
                          git commit + push main ───────────────┘
                                                                │  GitHub raw
                                                                ▼
                          easyhover2_suite.lua  ──(default)──► manifest.lua ─► dist/ files
                                                └──(--dev)───► manifest-dev.lua ─► source files
```

## Error handling

- Build parse failure → non-zero exit, name the file + luamin message, write no
  partial `dist/`.
- `run_gen --check` out of sync (either manifest) → fail the headless harness, as
  today.
- Dist acceptance gate not `OK` → block release; investigate with `systematic-debugging`
  (a divergence means luamin changed behaviour — likely a `serialise` order or a
  reflection edge case; the failing test names the module).
- Suite: an unknown/absent channel marker defaults to `min`; a corrupt marker is
  treated as `min` and rewritten.

## Reusability (follow-on, out of scope for this spec)

`build.mjs`, the two-manifest `gen_manifest` change, and the suite `--dev` flag form a
pattern to vendor into the other suite-based projects (EasyKey, DriveByWire, SecDoor,
LightController…), one isolated repo at a time, after it is proven on EasyHover 2.

## Out of scope

- Bundling / concatenation (would help file count, not bytes).
- Re-minifying basalt or shrinking the Basalt build.
- Identifier renaming beyond what luamin does by default.
- CI-based build (dist is committed, not CI-generated).

## Testing summary

- **Unit:** `build.mjs` — deterministic output; hard-fail on unparseable input;
  copy-through list respected; idempotent.
- **Unit:** `gen_manifest` — emits both manifests; `--check` catches drift in either;
  closure unchanged; basalt entry identical across channels.
- **Integration (the gate):** full CraftOS suite green against `dist/`
  (`tests/run_headless_dist.sh`).
- **Suite behaviour:** `--dev`/`--min` channel select + marker persistence; channel
  switch via repair keeps configs sacred.
