# EasyHover 2 Suite — install / update / repair + UI — design

Date: 2026-08-07
Status: approved-for-planning
Spec for: `easyhover2_suite.lua` (engine + UI) + `manifest.lua` + `tools/gen_manifest.lua` +
launchers + `fcs/io/config.lua` + suite tests

## 1. Purpose & scope

A single tool — `easyhover2_suite.lua` — run **directly from GitHub** (`wget run …`) that
installs, updates, and repairs EasyHover 2 on a fresh or existing CC:Tweaked computer. It **asks
which role** the computer is when nothing is installed, installs exactly what **that role** needs
(plus the shared debug tools), and makes it run on reboot. It carries no payload: it asks GitHub
(via a published `manifest.lua`) what the release contains and fetches only what this computer
needs. It presents a **proper graphical UI** with at-a-glance status, one-click actions, and
diagnostics.

This realises §16 of `docs/FCS_CORE_DESIGN.md`, with the UI brought forward to now (the pilot's
call — §16 deferred it). It is a **retarget of the proven, tested EasyHover 1 Suite**
(`../EasyHover/easyhover_suite.lua`): that engine already delivers every integrity property. We
reuse it near-verbatim, retarget constants, add a manifest-driven config hook, ship the full
`tools/` set to every role, switch to a single-latest backup, and add a custom UI.

**In scope:**
- The Suite engine retargeted to EH2 (checksum-every-run, all-or-nothing staging, config-sacred,
  cache-bust, independent self-update).
- Two roles, **`fcs`** and **`ui`**. Each installs **its own app + the full `tools/` debug set**;
  the role determines which app auto-runs at boot.
- The complete `tools/` debug set on **every** role, each reachable by a short terminal command
  after `Ctrl-T`.
- A **custom pure-CC graphical UI** for the Suite (single self-contained file).
- A Lua manifest generator run headless in CraftOS-PC.
- A standalone `fcs/io/config.lua` so config-extension is manifest-driven — **no change to
  `flight.lua`/`calibrate.lua` or the control stack**.
- **Single-latest** config backup policy.
- Ported unit + e2e test harness.
- Removing the now-obsolete `tools/install_*.lua`.

**Out of scope / deferred:**
- The **UI-role application build-out** (monitor selection/mirroring, config & calibration as UI
  menus, cockpit panels) — a substantial separate project, sequenced **after** the Suite. Captured
  in §11 so nothing is lost. The Suite ships whatever the UI app is today and re-ships future
  versions automatically, so it does **not** depend on that work.
- The **NAV** role (no `nav/` yet — a later manifest entry, no Suite change).
- Config schema-versioning + migrator (§15 additive-only, `schema = 1`).
- Shipping Basalt (Suite UI is custom; EH2 cockpit is custom too).
- **Building** no-op-gated flight-runtime instrumentation (a separate product feature — §8).

## 2. Requirements

Integrity requirements the v1 engine already satisfies (verifying, not inventing):

1. **Manifest-driven / no hardcoded lists** — the Suite hardcodes **zero** EH2 file lists.
2. **Suite version independent of EH2** — `manifest.updater` + `selfUpdateNotice`.
3. **No missed update from a stale/missing log** — per-file checksum vs manifest every run;
   version stamp is only a `--fast` opt-out; missing/corrupt record → full verify + role detect.
4. **Defeat GitHub CDN caching** — `?cb=<epoch>` + `no-cache` headers on every fetch.

Pilot decisions this session:

5. **Per-role install, not a whole-repo dump** — ask for a role when nothing is installed; install
   exactly that role's app closure **plus** the shared tools; update only the current role; on a
   broken/unknown install, detect the role, repair, and set it correctly, or clean-reinstall a
   chosen role if too broken.
6. **All `tools/` on every role** — the full diagnostic tool set ships to both roles, each a short
   terminal command (`calibrate`, `hovertest`, `probe`, …) usable after `Ctrl-T`.
7. **Config is sacred, backup is single-latest** — configs are never fully deleted; on update they
   are additively merged; a config is replaced with fresh **only if it will not parse at all**, and
   even then it is backed up first. The backup folder holds **exactly one** backup — the latest —
   replaced on each run that touches config.
8. **Proper Suite UI now** — custom pure-CC, fancy on Advanced computers, degrading to keyboard on
   Basic.

## 3. Architecture & components

Five deliverables.

### 3.1 `easyhover2_suite.lua` (repo root) — engine + UI, single self-contained file
Retarget of `easyhover_suite.lua`. Engine behaviour carried over: `Suite.checksum` (FNV-1a 32-bit,
LF-normalised, split multiply); `fetchOnce`/`fetch` (cache-bust + retry); `Suite.integrity` /
`Suite.choosePlan` / `Suite.detectRole` (bytes, not trust); all-or-nothing `<dst>.eh2new` staging;
`PROTECTED` + `guard()` before every release write/delete; `clearRole`/`pruneRole`; timestamped-
→ **single-latest** backups (§6); `selfUpdateNotice`; args
`--check`/`--repair`/`--fast`/`--list`/`--help`/`<role>`.

**Changed for EH2:**

| Constant | Value |
|---|---|
| `DEFAULT_BASE` | `https://raw.githubusercontent.com/maar-10/EasyHover2/main` |
| `SOURCE_FILE` | `/easyhover2_suite_src.txt` |
| `TOKEN_FILE` | `/easyhover2_suite_token.txt` (repo is public; token optional) |
| `STATE_FILE` | `/easyhover2_install.txt` |
| `BACKUP_ROOT` | `/easyhover2_backup` (single-latest — §6) |
| `STAGE` | `.eh2new` |
| `PROTECTED` | `^/eh2_.*%.tbl$`, `^/eh2_.*%.log$`, `^/easyhover2_backup`, `^/easyhover2_install%.txt$`, `^/easyhover2_suite_src%.txt$`, `^/easyhover2_suite_token%.txt$` |

Plus: manifest-driven config hook (§6), `detectRole` adaptation (§4), embedded UI (§7).

### 3.2 `tools/gen_manifest.lua` — Lua generator, run headless in CraftOS-PC
Replaces v1's `gen_manifest.js`. Emits `manifest.lua`. Shares the **exact** FNV-1a with the Suite
(one `tools/fnv1a.lua`; the Suite keeps an identical inline copy to stay a single `wget run` file).
Computes each role's closure (§4), digests `version`, reads `updater` (the Suite's own size+sum).
Modes: default (write), `--check` (in-sync assert), `--selftest` (reference checksums).

### 3.3 Launchers (`launchers/`) — thin root programs
Each sets `package.path = "/?.lua;/?/init.lua;"` and `require`s an entry:
- `launchers/fcs.lua` → `/startup.lua` on **fcs** → `require("tools.flight")`.
- `launchers/ui.lua` → `/startup.lua` on **ui** → `require("ui.main")`.
- App command per role: `launchers/flight.lua` → `flight` (fcs); `launchers/cockpit.lua` →
  `cockpit` (ui).
- Diagnostic commands on **both** roles: `launchers/{calibrate,hovertest,probe,probemodem,
  probebatch}.lua` → `calibrate` / `hovertest` / `probe` / `probemodem` / `probebatch`.

### 3.4 `fcs/io/config.lua` — standalone config module (new)
Implements the `configModule` contract the Suite's config-extension expects, wrapping the existing
`fcs/io/hwconfig.lua` and mirroring `calibrate.lua`'s save. **Used only by the Suite.**
`flight.lua`/`calibrate.lua` are unchanged (§6).

### 3.5 Tests (`tests/`)
`tests/test_suite.lua` (pure-logic + UI-layout units + FNV parity), `tests/suite_probe.lua` +
`tests/run_suite_e2e.sh` (real headless install/update/repair against a localhost mirror).

## 4. Role model — per-role app + all tools

Nothing installed → the Suite asks the role → installs **that role's closure** → sets its boot app.
Each role's install is its **own app** plus the **shared diagnostic tools**. The role is not a
whole-repo dump: FCS does not ship the cockpit; UI does not ship the FCS flight app. Both ship the
diagnostic tools (which pull in the shared control/io stack), so the diagnostics run on either
machine — flight-hardware tools simply error on a UI PC (no thruster/sensor peripherals), the
accepted cost of "tools everywhere".

### Membership = dependency-closure of the role's roots
A role's file set is the transitive `require()` closure of its roots:

- **Common to both roles (diagnostic tools):** `calibrate`, `hovertest`, `probe`, `probemodem`,
  `probebatch` (their tool files + launchers).
- **`fcs` roots (adds):** `tools/flight.lua` (the flight app) + `flight` launcher + `fcs`
  startup launcher.
- **`ui` roots (adds):** `ui/main.lua` (the cockpit) + `cockpit` launcher + `ui` startup launcher.
- Both roles also include `fcs/io/config.lua` (the declared `configModule`).

Closure derivation (pure, unit-tested): scan each root for `require("mod.name")` (pattern
`require%s*%(?%s*["']([%w%._%-]+)["']`), map `mod.name` → `mod/name.lua` (else `mod/name/init.lua`)
via the package.path convention, resolve against the repo root, recurse, union the roots. An
unresolvable `require` is a **hard error** at generation time. Using the closure (not "walk a
directory") makes membership automatic and correct-by-construction, and it **excludes** non-product
files (`tests/`, `docs/`, `backup/`, `.superpowers/`, and dev-only tools not listed as roots —
`install_*.lua`, `fix_yaw_sign.lua`).

### What each role ends up with
- **`ui`-unique:** `ui/*` (cockpit/dispatch/render/widget/main), the `cockpit` command, the `ui`
  startup launcher.
- **`fcs`-unique:** `tools/flight.lua`, `fcs/runtime/flight.lua`, `fcs/input/*`, the `flight`
  command, the `fcs` startup launcher.
- **Shared (both):** the diagnostic tools and their closure — the control/io/comms/frame/angle
  stack, `fcs/io/config.lua`.

### `detectRole` adaptation
The two roles share most files but each has unique files **and** a distinct installed
`/startup.lua`. `detectRole`:
1. **Primary:** match the on-disk `/startup.lua` size+sum against each role's startup-launcher
   entry in the manifest — an unambiguous signal of the installed role.
2. **Corroboration/fallback:** if `startup.lua` is absent or hand-edited, count each role's
   **unique** files present (`ui/*` vs `fcs/input/*`+`tools/flight.lua`) and take the clear
   winner; if neither is clearly present, prompt.

Both branches are pure functions, unit-tested off the filesystem.

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
      ["dirs"]={ "fcs","tools" }, ["configs"]={ "/eh2_hw_config.tbl" },
      ["configModule"]="fcs.io.config", ["luaPath"]="/", ["entry"]="startup.lua",
      ["files"]={ { ["src"]="…", ["dst"]="…", ["size"]=<n>, ["sum"]="<fnv>" }, … },
    },
    ["ui"] = { ["title"]="Cockpit display", …, ["dirs"]={ "ui","fcs","tools" }, … },
  },
}
```

`dirs` (repair scope) are derived from the role's closure paths. `version` moves only when shipped
bytes move; `schema` bumps only on an incompatible config layout change (not now).

## 6. Config-extension & single-latest backup — no flight-code changes

`flight.lua` and `calibrate.lua` both read `/eh2_hw_config.tbl` and
`hwconfig.merge(saved, hwconfig.defaults())`; `calibrate.lua` also saves via tmp-write+move+
`serialise`. **None of that changes.**

**Config-extension (manifest-driven).** The manifest declares a per-role `configModule`; the Suite
`require`s it and calls the same three-function contract v1 used:
- `Config.load(path) -> cfg, existed, err` — read + `unserialise` the saved table (never throws).
- `Config.withDefaults(cfg) -> cfg` — `hwconfig.merge(cfg or {}, hwconfig.defaults())`.
- `Config.save(path, cfg) -> ok, err` — tmp-write + move + `serialise` (mirrors `calibrate`).

`Suite.extendConfig` (behaviour from v1): back up the config; `load`; if it parses,
`save(withDefaults(cfg))` → **extended** (additive: new defaults appear, set values kept); if
unparseable (already backed up) → rewrite defaults → **quarantined**; absent → left for first run.
`fcs/io/config.lua` is a **new standalone module** implementing that contract over the existing
`hwconfig`; used only by the Suite; shipped as the declared `configModule`. The control stack and
stable-hover code are untouched.

**Single-latest backup.** Config is in `PROTECTED`, so it is never deleted or overwritten by a
release write, in install / update / repair / role-switch alike. Before a config is touched, the
Suite backs it up to `/easyhover2_backup/`, **replacing any previous backup** so the folder holds
exactly one (the latest) — a change from v1's per-run timestamped folders, per §16. Repair
(`clearRole`) clears only the role's owned code dirs; root-level configs are structurally out of
reach and `guard()`-protected regardless.

## 7. Suite UI (custom pure-CC, single-file, graceful degrade)

The Suite renders a graphical dashboard using only CC's own `term`/`window`/`paintutils` — no
Basalt, so it stays one self-contained `wget run` file with no bootstrap fetch. All UI code lives
inside `easyhover2_suite.lua`.

**Degrade.** Advanced computer (`term.isColour()`) → full graphical UI + mouse. Basic computer →
the v1 keyboard flow (tested role picker + text prompts + progress lines). Same engine underneath.

**Dashboard.**
- Title bar with filled background; bordered panels with pseudo-rounded corners.
- **Status:** current role · installed → release version (green current / yellow update / red
  repair) · schema · last-install time · source URL · Suite-self status.
- **Integrity:** files OK / changed / missing (from `Suite.integrity`) with a summary bar.
- **Actions:** Install/Update · Verify · Repair · Switch role · Check (dry-run); a **progress bar**
  over fetch → stage → commit.
- **Diagnostics / tools:** a "Launch tool ▸" list of the shipped diagnostic commands, plus a
  log/diag view when logs are present (ties to §8).

**Testability.** Layout/geometry are **pure functions** (panel rects, progress-bar fill, status
colour from plan state, `rolePickerLayout`), separated from drawing/IO, asserted at multiple
terminal sizes without a screen. Drawing + event loop are thin.

**"Smooth" honestly.** CC is a character grid; on Advanced computers we get filled backgrounds,
bordered panels, progress bars, and pseudo-rounded corners — clean, not antialiased.

## 8. Instrumentation / logging (noted for the plan — not built here)

Per the pilot: the full EH2 should have **flight-runtime instrumentation for logging, gated behind
a switch that no-ops it in normal flight**. Today `fcs/bringup/instrument.lua` is a pure CSV/summary
logger wired only into `hover_test.lua`, **not** the flight app. Wiring a no-op-gated logging
facility into `tools/flight.lua` is a **separate product feature** (it touches the just-stabilised
flight loop and must be designed/tested on its own). This Suite **ships** whatever instrumentation
modules exist (they enter the closure automatically) and the **UI diagnostics view surfaces logs**
when present. The plan records this as a distinct later feature; it is not implemented here.

## 9. FNV-1a parity & trust

One FNV-1a implementation used by both sides; parity enforced by (a) generator `--selftest`
reference checksums asserted in `tests/test_suite.lua`, and (b) every fetched file's `sum` verified
against the manifest during install. Trust root is HTTPS to the pinned `raw.githubusercontent.com`
URL; FNV-1a + size answer "did this change / arrive intact", not a signature. EasyHover2 is
**public**, so `wget run` needs no token; `TOKEN_FILE` is a fallback for a future private mirror.

## 10. Testing

- **Unit** (`tests/test_suite.lua`, under `tests/run_headless.sh`): `choosePlan` truth table;
  `integrity` (missing/corrupt/ok via injected `read`); `detectRole` (startup-launcher match +
  unique-file fallback); `parseState` tolerance; `isProtected` for every EH2 pattern; **closure
  derivation** (pure, injected `readFile`) incl. per-role roots and the unresolvable-require error;
  **UI layout** purity at basic + advanced sizes; **FNV parity** vs generator `--selftest`;
  `fcs/io/config.lua` load/withDefaults/save round-trip incl. additive-merge and
  unparseable-quarantine; **single-latest backup** (a second backup replaces the first).
- **e2e** (`tests/run_suite_e2e.sh` + `tests/suite_probe.lua`): serve the repo on localhost, point
  the Suite via `_src.txt`, run real phases — `install` (asks/sets role), `current`, `configkeep`
  (a pilot value survives an update), `update` (a changed file re-fetched, config kept), `repair`
  (corrupt a file → clean reinstall, config kept, single backup), `badconfig` (unparseable config
  quarantined + backed up), `detect` (missing record → role detected from startup launcher),
  `protect` (a manifest naming a protected path refused by `guard`), `check` (dry run writes
  nothing), a fresh install of the **other** role, and a **role-switch** (fcs→ui). Probe drives via
  `--script`.
- **e2e server:** **python** `http.server` primary (verified: Python 3.14 + curl); harness is
  **server-agnostic with a fallback** to another static server if python is absent.
- **Generator sync guard:** `tools/gen_manifest.lua --check` asserts the committed manifest matches
  the tree; wired into the suite test run.

## 11. Deferred: UI-role application build-out (next project)

Captured so it is not lost; **sequenced after** the Suite, as its own spec → plan. The Suite ships
whatever the UI app is at each release, so this does not block or depend on the Suite. The UI role's
cockpit application must eventually include:
- **Monitor selection per UI panel** — assign each panel to a specific physical monitor, including
  **mirroring the two overhead panels** and the **flight-path markers** across monitors.
- **Config & calibration as UI menus** — the interactive binding menu and the full calibration
  setup (the same processes shipped as the `tools/` `calibrate`/config commands) in a friendlier
  on-screen menu form.
- **The cockpit panels** discussed so far.

## 12. Open items / risks (for the plan)

1. **Shipped command list — confirmed:** `flight` (fcs), `cockpit` (ui), and `calibrate`,
   `hovertest`, `probe`, `probemodem`, `probebatch` (both). Excluded (obsolete/one-off):
   `install_hovertest.lua`, `install_probe.lua`, `fix_yaw_sign.lua`. The closure roots ARE this
   list, so it fully determines what ships.
2. **Remove `tools/install_*.lua` — confirmed** (obsoleted by the Suite). Part of this work.
3. **`require` scanner completeness** — matches literal `require("string")`; the plan asserts (a
   grep) that no shipped entry uses a computed require, so the closure is complete.
4. **Single-file size** — engine + embedded UI in one file; acceptable for `wget run`; it is the
   `updater` the manifest tracks.
5. **No-op-gated flight instrumentation** (§8) — separate feature, flagged not built.
```
