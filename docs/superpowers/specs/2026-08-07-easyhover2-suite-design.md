# EasyHover 2 Suite — install / update / repair + UI — design

Date: 2026-08-07
Status: approved-for-planning
Spec for: `easyhover2_suite.lua` (engine + UI) + `manifest.lua` + `tools/gen_manifest.lua` +
launchers + `fcs/io/config.lua` + suite tests

## 1. Purpose & scope

A single tool — `easyhover2_suite.lua` — run **directly from GitHub** (`wget run …`) that
installs, updates, and repairs EasyHover 2 on a fresh or existing CC:Tweaked computer, choosing a
**role** (which app auto-runs on boot). It carries no payload: it asks GitHub (via a published
`manifest.lua`) what the current release contains and fetches only what this computer needs. It
presents a **proper graphical UI** with at-a-glance status, one-click actions, and diagnostics.

This realises §16 of `docs/FCS_CORE_DESIGN.md` (with the UI brought forward to now, per the
pilot's decision — §16 originally deferred it). It is a **retarget of the proven, tested
EasyHover 1 Suite** (`../EasyHover/easyhover_suite.lua`): that engine already delivers every
integrity property we need. We reuse it near-verbatim, retarget constants, add a manifest-driven
config hook, ship the full tool set to every role, and add a custom UI.

**In scope:**
- The Suite engine retargeted to EH2 (checksum-every-run, all-or-nothing staging, config-sacred,
  cache-bust, independent self-update).
- Two roles, **`fcs`** and **`ui`**, that install an **identical full product** and differ only
  in which app auto-runs at boot.
- Shipping the **complete `tools/` debug set** to every role, each reachable by a short terminal
  command (`calibrate`, `hovertest`, `probe`, …) after `Ctrl-T`.
- A **custom pure-CC graphical UI** for the Suite (single self-contained file).
- A Lua manifest generator run headless in CraftOS-PC.
- A standalone `fcs/io/config.lua` so config-extension is manifest-driven — **no change to
  `flight.lua`/`calibrate.lua` or the control stack**.
- Ported unit + e2e test harness.

**Out of scope / deferred:** the **NAV** role (no `nav/` yet — a later manifest entry, no Suite
change); config schema-versioning + migrator (§15 additive-only, `schema = 1`); shipping Basalt
(Suite UI is custom; EH2 cockpit is custom too); **building** no-op-gated flight-runtime
instrumentation (a separate product feature — see §8, noted for the plan, not built here).

## 2. Requirements (from brainstorming)

The v1 suite already satisfies the four integrity requirements; verifying, not inventing:

1. **Manifest-driven / no hardcoded lists** — the Suite hardcodes **zero** EH2 file lists; roles,
   files, dirs, entry, `configModule`, config paths, `luaPath` all come from `manifest.lua`. A
   future EH2 change needs only a regenerated manifest.
2. **Suite version independent of EH2** — the Suite flags **itself** stale only when a new Suite
   ships (`manifest.updater` = the Suite's own size+sum; `selfUpdateNotice`).
3. **No missed update from a stale/missing log** — decision is **per-file checksum vs manifest**
   every run; the version stamp is only a `--fast` opt-out; a missing/corrupt record falls back to
   full verification + on-disk role detection.
4. **Defeat GitHub CDN caching** — every fetch appends `?cb=<epoch>` + `no-cache` headers.

Plus three pilot decisions in this session:

5. **Full install on every role** — every role installs the identical complete product (all app
   code + all debug tools); the role only chooses the boot app.
6. **Debug tools as terminal commands** — after `Ctrl-T`, typing `calibrate` / `hovertest` /
   `probe` / … starts the respective tool.
7. **Proper Suite UI now** — custom pure-CC, fancy on Advanced computers, degrading to keyboard on
   Basic.

## 3. Architecture & components

Five deliverables:

### 3.1 `easyhover2_suite.lua` (repo root) — engine + UI, single self-contained file
Retarget of `easyhover_suite.lua`. Engine behaviour carried over unchanged: `Suite.checksum`
(FNV-1a 32-bit, LF-normalised, split multiply); `fetchOnce`/`fetch` (cache-bust + retry);
`Suite.integrity` / `Suite.choosePlan` / `Suite.detectRole` (bytes, not trust); all-or-nothing
`<dst>.eh2new` staging; `PROTECTED` + `guard()` before every release write/delete;
`clearRole`/`pruneRole`; timestamped backups; `selfUpdateNotice`; args
`--check`/`--repair`/`--fast`/`--list`/`--help`/`<role>`.

**Changed for EH2:**

| Constant | Value |
|---|---|
| `DEFAULT_BASE` | `https://raw.githubusercontent.com/maar-10/EasyHover2/main` |
| `SOURCE_FILE` | `/easyhover2_suite_src.txt` |
| `TOKEN_FILE` | `/easyhover2_suite_token.txt` (repo is public; token optional) |
| `STATE_FILE` | `/easyhover2_install.txt` |
| `BACKUP_ROOT` | `/easyhover2_backup` |
| `STAGE` | `.eh2new` |
| `PROTECTED` | `^/eh2_.*%.tbl$`, `^/eh2_.*%.log$`, `^/easyhover2_backup`, `^/easyhover2_install%.txt$`, `^/easyhover2_suite_src%.txt$`, `^/easyhover2_suite_token%.txt$` |

Plus: manifest-driven config hook (§6) and the embedded UI (§7).

### 3.2 `tools/gen_manifest.lua` — Lua generator, run headless in CraftOS-PC
Replaces v1's `gen_manifest.js`. Emits `manifest.lua`. Shares the **exact** FNV-1a with the Suite
(both use one `tools/fnv1a.lua`; the Suite also keeps an identical inline copy so it stays a single
`wget run` file). Computes the **product closure** (§4), assigns it to both roles with per-role
startup launchers, digests `version`, reads `updater` (the Suite's own size+sum). Modes: default
(write), `--check` (in-sync assert), `--selftest` (reference checksums).

### 3.3 Launchers (`launchers/`) — thin root programs
Each sets `package.path = "/?.lua;/?/init.lua;"` and `require`s an entry:

- `launchers/fcs.lua` → installed as `/startup.lua` on the **fcs** role → `require("tools.flight")`.
- `launchers/ui.lua` → installed as `/startup.lua` on the **ui** role → `require("ui.main")`.
- Shared command launchers, installed on **both** roles at the root:
  `flight`, `cockpit`, `calibrate`, `hovertest`, `probe`, `probemodem`, `probebatch`
  (each `require`s its `tools.*` / `ui.main`). Final command list confirmed in the plan (§11).

### 3.4 `fcs/io/config.lua` — standalone config module (new)
Provides the three-function `configModule` contract the Suite's config-extension expects, wrapping
the **existing** `fcs/io/hwconfig.lua` and mirroring `calibrate.lua`'s save. **Used only by the
Suite.** `flight.lua`/`calibrate.lua` are unchanged (§6).

### 3.5 Tests (`tests/`)
`tests/test_suite.lua` (pure-logic units + UI-layout units + FNV parity), `tests/suite_probe.lua`
+ `tests/run_suite_e2e.sh` (real headless install/update/repair against a localhost mirror).

## 4. Role model — identical full install, role picks the boot app

Both roles install the **same complete product**; the only per-role difference is which launcher
becomes `/startup.lua`. Every role therefore carries both apps and all debug-tool commands, so on
any EH2 computer you can `Ctrl-T` and type `calibrate`, `hovertest`, etc. (Flight tools on a UI PC
simply error if run — no thruster/sensor peripherals — which is the accepted cost of "everything
at hand.")

### Product file set = dependency-closure of all entry points
The shipped set is computed automatically as the transitive `require()` closure of **every**
shipped entry point — the two apps plus every debug-tool command:

1. Roots = `tools/flight.lua`, `ui/main.lua`, `tools/calibrate.lua`, `tools/hover_test.lua`,
   `tools/probe.lua`, `tools/probe_modem.lua`, `tools/probe_batch.lua` (final list per §11), plus
   the launcher files and `fcs/io/config.lua`.
2. Scan each for `require("mod.name")` (pattern `require%s*%(?%s*["']([%w%._%-]+)["']`), map
   `mod.name` → `mod/name.lua` (else `mod/name/init.lua`) via the package.path convention, resolve
   against the repo root, recurse; union all roots.
3. An unresolvable `require` (names a file not in the repo) is a **hard error** at generation time
   — a real missing dependency, caught before release. CC built-ins are globals, never `require`d,
   so there is nothing to filter.

Using the closure (rather than "walk a directory") is what makes shipping automatic and
correct-by-construction, and it **excludes** non-product files (tests/, docs/, `backup/`,
`.superpowers/`, and dev-only tools we don't list as roots — `install_*.lua`, `fix_yaw_sign.lua`)
without a manual denylist. Closure derivation is a **pure function** (`roots, readFile → sorted
files`), unit-tested off the filesystem.

### The two roles

| | `fcs` — Flight computer | `ui` — Cockpit display |
|---|---|---|
| Boot app (`/startup.lua`) | `launchers/fcs.lua` → `tools.flight` | `launchers/ui.lua` → `ui.main` |
| Shipped files | the full product closure | the full product closure (identical) |
| Command set | all (flight + tools) | all (flight + tools) |
| Owned dirs (repair scope) | derived from closure paths (`fcs`, `ui`, `tools`) | same |
| Config | `/eh2_hw_config.tbl`, `configModule = "fcs.io.config"` | same (present; harmless if unused) |
| `luaPath` | `/` | `/` |

Because both roles ship the identical closure, their `files[]` differ only in the `/startup.lua`
entry's `src`+`sum`. Switching roles is a role-change: the shared root `startup.lua` is replaced by
the new role's launcher; the rest is already correct, so no re-download churn beyond the launcher.

**`detectRole` adaptation.** v1 detected the role from disjoint per-role file sets — which cannot
work here, since both roles ship the same files. For EH2 the distinguishing artifact is the
installed `/startup.lua`: `detectRole` identifies the role by matching the on-disk `startup.lua`'s
size+sum against each role's launcher entry in the manifest (falling back to "product present but
role unknown" → prompt, if it matches neither, e.g. a hand-edited startup). This is the one
engine-logic change beyond constants; it is a pure function and unit-tested.

## 5. Manifest schema (`manifest.lua`)

Generated data table (parsed with `textutils.unserialise` in an empty env — inert):

```lua
{
  ["base"]    = "https://raw.githubusercontent.com/maar-10/EasyHover2/main",
  ["version"] = "<12-hex digest of every shipped file's role:dst:sum:size>",
  ["schema"]  = 1,
  ["updater"] = { ["size"] = <n>, ["sum"] = "<fnv>" },   -- easyhover2_suite.lua itself
  ["roles"] = {
    ["fcs"] = {
      ["title"]="Flight computer", ["blurb"]="…", ["status"]="released",
      ["dirs"]={ "fcs","tools","ui" }, ["configs"]={ "/eh2_hw_config.tbl" },
      ["configModule"]="fcs.io.config", ["luaPath"]="/", ["entry"]="startup.lua",
      ["files"]={ { ["src"]="…", ["dst"]="…", ["size"]=<n>, ["sum"]="<fnv>" }, … },
    },
    ["ui"] = { ["title"]="Cockpit display", …, ["configModule"]="fcs.io.config", … },
  },
}
```

`version` moves only when shipped bytes move; `schema` bumps only on an incompatible config layout
change (not now).

## 6. Config-extension, manifest-driven — no flight-code changes

`flight.lua` and `calibrate.lua` both read `/eh2_hw_config.tbl` and
`hwconfig.merge(saved, hwconfig.defaults())`; `calibrate.lua` also saves via tmp-write+move+
`serialise`. **None of that changes.**

The manifest declares a per-role `configModule`; the Suite `require`s it and calls the same
three-function contract v1 used:

- `Config.load(path) -> cfg, existed, err` — read + `unserialise` the **saved** table (never
  throws).
- `Config.withDefaults(cfg) -> cfg` — `hwconfig.merge(cfg or {}, hwconfig.defaults())`.
- `Config.save(path, cfg) -> ok, err` — tmp-write + move + `serialise` (mirrors `calibrate`).

`Suite.extendConfig` (behaviour unchanged from v1): back up the config; `load`; if it parses,
`save(withDefaults(cfg))` → **extended**; if unparseable (already backed up) → rewrite defaults →
**quarantined**; absent → left for first run. `fcs/io/config.lua` is a **new standalone module**
implementing that contract over the existing `hwconfig`; it is used only by the Suite and is
shipped because it is the declared `configModule`. The control stack (PID/mixer/actuate/sensors)
and the stable-hover code are untouched.

## 7. Suite UI (custom pure-CC, single-file, graceful degrade)

The Suite renders a graphical dashboard using only CC's own `term`/`window`/`paintutils` — no
Basalt, so the Suite stays one self-contained `wget run` file with no bootstrap fetch. All UI code
lives inside `easyhover2_suite.lua`.

**Capability detection & degrade.** On an **Advanced** computer (`term.isColour()`), draw the full
graphical UI with mouse support. On a **Basic** computer (no colour / no mouse), fall back to the
v1 keyboard flow (the tested role picker + text prompts + progress lines). The UI layer sits on
top of the same engine functions; no engine behaviour depends on which front-end is active.

**Dashboard (main screen).**
- Title bar with a filled background; panels with borders and pseudo-rounded corners.
- **Status panel:** current role · installed version → release version (colour-coded:
  green = current, yellow = update available, red = repair needed) · schema · last-install time ·
  source URL · Suite-self status (current / new Suite available).
- **Integrity panel:** files OK / changed / missing (from `Suite.integrity`), with a summary bar.
- **Actions:** Install/Update · Verify (re-checksum) · Repair · Switch role · Check (dry-run).
  During work, a **progress bar** reflects fetch → stage → commit.
- **Diagnostics / tools:** a "Launch tool ▸" affordance listing the shipped debug commands
  (`calibrate`, `hovertest`, `probe`, …) so they can be started from the Suite, plus a log/diag
  view when logs are present (ties to §8).

**Testability.** Layout/geometry are **pure functions** (panel rects, progress-bar fill, status
colour from plan state, the existing `rolePickerLayout`), separated from drawing and IO, so
`tests/test_suite.lua` asserts them at multiple terminal sizes without a screen. Drawing and the
event loop are thin.

**Honesty about "smooth."** CC is a character grid; on Advanced computers we get filled colour
backgrounds, bordered panels, progress bars, and pseudo-rounded corners — visually clean, but not
antialiased. Set expectations accordingly.

## 8. Instrumentation / logging (noted for the plan — not built here)

Reminder captured per the pilot: the full EasyHover 2 should have **flight-runtime instrumentation
for logging, gated behind a switch that no-ops it in normal flight**. Today `fcs/bringup/
instrument.lua` is a pure CSV/summary logger wired only into `hover_test.lua`, **not** the flight
app. Wiring a no-op-gated logging facility into `tools/flight.lua` is a **separate product
feature** (it would touch the just-stabilised flight loop and must be designed/tested on its own).
This Suite:
- **ships** whatever instrumentation modules exist (they enter the closure automatically), and
- the **UI diagnostics view surfaces logs** when present.

The plan records this as a distinct, later feature; it is not implemented as part of the Suite.

## 9. FNV-1a parity & trust

One FNV-1a implementation, used by both sides; parity enforced by (a) generator `--selftest`
reference checksums asserted in `tests/test_suite.lua`, and (b) every fetched file's `sum` verified
against the manifest during install (a divergence fails the whole install, never slips through).
Trust root is HTTPS to the pinned `raw.githubusercontent.com` URL (as for `wget run`); FNV-1a +
size answer "did this change / arrive intact", not a signature. EasyHover2 is **public**, so
`wget run` needs no token; `TOKEN_FILE` is a fallback for a future private mirror/fork.

## 10. Testing

- **Unit** (`tests/test_suite.lua`, under `tests/run_headless.sh`): `choosePlan` truth table;
  `integrity` (missing/corrupt/ok via injected `read`); `detectRole` (both roles ship the same
  closure, so detection keys off the record and, when absent, the shared file set → role from the
  installed startup launcher); `parseState` tolerance; `isProtected` for every EH2 pattern;
  **closure derivation** (pure, injected `readFile`); **UI layout** purity (panel rects,
  progress-bar fill, status-colour mapping, `rolePickerLayout`) at basic + advanced sizes; **FNV
  parity** vs generator `--selftest`; `fcs/io/config.lua` load/withDefaults/save round-trip incl.
  additive-merge and unparseable-quarantine.
- **e2e** (`tests/run_suite_e2e.sh` + `tests/suite_probe.lua`): serve the repo on localhost, point
  the Suite via `_src.txt`, run real phases — `install`, `current`, `configkeep` (a pilot value
  survives an update), `repair` (corrupt a file → clean reinstall, config kept), `badconfig`
  (unparseable config quarantined + backed up), `detect` (missing record → role detected),
  `protect` (a manifest naming a protected path is refused by `guard`), `check` (dry run writes
  nothing), plus a fresh install of the **other** role and a **role-switch** (fcs→ui replaces only
  the launcher). Probe drives via `--script` (never overwriting its own `/startup.lua`).
- **e2e server:** **python** `http.server` primary (verified: Python 3.14 + curl). The harness is
  **server-agnostic with a fallback**: it probes for python and, if absent, falls back to another
  static file server present on the machine, so the e2e runs without python too.
- **Generator sync guard:** `tools/gen_manifest.lua --check` asserts the committed manifest matches
  the tree; wired into the suite test run so a forgotten regenerate fails CI.

## 11. Open items / risks (for the plan)

1. **Exact shipped command list.** Proposed roots: `flight`, `cockpit`, `calibrate`, `hovertest`,
   `probe`, `probemodem`, `probebatch`. Proposed **exclusions** (dev-only / superseded):
   `install_hovertest.lua`, `install_probe.lua` (obsoleted by this Suite), `fix_yaw_sign.lua`
   (one-off correction). Confirm at plan start; the closure roots ARE this list, so it fully
   determines what ships.
2. **`require` scanner completeness.** It matches literal `require("string")`. The plan asserts (a
   grep) that no shipped entry uses a computed/non-literal require, so the closure is complete.
3. **Single-file size.** Engine + embedded UI in one file grows `easyhover2_suite.lua`; acceptable
   for `wget run`, and it is the `updater` the manifest tracks.
4. **No-op-gated flight instrumentation** (§8) is a separate feature, flagged not built.
5. **Legacy installers.** Once the Suite ships, `tools/install_*.lua` are dead; the plan may remove
   them (separate small cleanup) so they are not mistaken for the supported path.
```
