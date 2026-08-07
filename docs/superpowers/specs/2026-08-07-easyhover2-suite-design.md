# EasyHover 2 Suite — install / update / repair — design

Date: 2026-08-07
Status: approved-for-planning
Spec for: `easyhover2_suite.lua` + `manifest.lua` + `tools/gen_manifest.lua` + launchers + suite tests

## 1. Purpose & scope

A single tool — `easyhover2_suite.lua` — run **directly from GitHub** (`wget run …`) that
installs, updates, and repairs any EasyHover 2 role on a fresh or existing CC:Tweaked computer.
It carries no payload: it asks GitHub (via a published `manifest.lua`) what the current release
contains and fetches only what this computer needs.

This realises §16 of `docs/FCS_CORE_DESIGN.md`. It is a **retarget of the proven, tested
EasyHover 1 Suite** (`../EasyHover/easyhover_suite.lua`), not a from-scratch build: that engine
already delivers every property §16 asks for. We reuse it near-verbatim and change only what is
genuinely different for EH2.

**In scope (this spec):** the Suite engine retargeted to EH2; two released roles **`fcs`** and
**`ui`**; a Lua manifest generator run headless in CraftOS-PC; boot launchers; a small
`fcs/io/config.lua` config module so config-extension is manifest-driven; the ported unit + e2e
test harness.

**Out of scope / deferred:** the **NAV** role (no `nav/` code exists yet — declared later, as a
manifest entry, with no Suite change); any Suite **UI** (§16: "no UI yet"); config
schema-versioning + migrator (§15 — additive-only for now, `schema = 1`); shipping Basalt
(EH2's cockpit is the custom immediate-mode toolkit — no Basalt dependency).

## 2. Requirements (from brainstorming)

The v1 suite already satisfies all four; verifying, not inventing:

1. **Fully modular / manifest-driven** — the Suite hardcodes **zero** EH2 file lists. Roles,
   files, dirs, entry, config module, config paths, `luaPath` all come from `manifest.lua`. A
   future EH2 change needs only a regenerated manifest, never a Suite code change. *(v1: every
   behaviour reads `manifest.roles`.)*
2. **Suite version independent of EH2** — the Suite flags **itself** out of date only when a
   genuinely new Suite ships, never because a role's content moved. *(v1: `manifest.updater`
   carries the Suite's own size+sum; `selfUpdateNotice` compares only that.)*
3. **No missed update from a stale/missing log** — the authoritative "what needs changing"
   decision is **per-file checksum vs manifest**, computed every run; the version stamp is only a
   `--fast` opt-out and can never *cause* a miss. A missing/corrupt install record falls back to
   full byte-verification and on-disk role detection, never a false "current". *(v1:
   `Suite.integrity` always runs by default; `noRecord → repair`; `detectRole`.)*
4. **Defeat GitHub CDN caching** — every fetch appends a unique `?cb=<epoch>` cache-key and sends
   `Cache-Control/Pragma: no-cache`, so a just-pushed file is never masked by a stale Fastly
   edge copy. *(v1: `fetchOnce`.)*

## 3. Architecture & components

Four deliverables:

### 3.1 `easyhover2_suite.lua` (repo root)
A retarget of `easyhover_suite.lua`. The engine is carried over **unchanged in behaviour**:

- **Checksum:** FNV-1a 32-bit over LF-normalised bytes, lower-case hex (`Suite.checksum`). Split
  32-bit multiply in 16-bit halves to stay under the 2^53 double limit — byte-for-byte identical
  to the generator.
- **Fetch:** `fetchOnce` (cache-bust + no-cache headers, optional token) with a one-retry
  `fetch`.
- **Integrity / plan:** pure `Suite.integrity(spec, read)`, `Suite.choosePlan(s)`,
  `Suite.detectRole(manifest, exists)` — install / update / repair / current decided from bytes,
  not trust. "Update and corruption look identical on disk; the version stamp tells them apart;
  missing files alone prove nothing."
- **All-or-nothing staging:** every file downloaded + checksum-verified into `<dst>.eh2new`, and
  only once **all** arrive intact are they `fs.move`d into place. A drop half-way leaves the
  install exactly as it was.
- **Config sacred:** `PROTECTED` Lua patterns + `guard(path)` asserted immediately before **every**
  release write and delete, so a wrong manifest still cannot clobber a config. Repair
  (`clearRole`) is scoped to the role's own `dirs`; `pruneRole` drops files a release no longer
  ships, run **after** the new files are committed.
- **Backups:** one timestamped `/easyhover2_backup/<ts>_<version>/` folder per run that needs it;
  copy-never-move so a failed run costs nothing.
- **Self-update:** `selfUpdateNotice` replaces the Suite's own file iff its bytes differ from
  `manifest.updater`; names a release inconsistency rather than blaming the computer.
- **Args:** `--check` (dry run), `--repair`, `--fast`, `--list`, `--help`, `<role>` (install/switch).
- **Role picker:** `rolePickerLayout` + `askForRole` (pure layout, testable at every terminal
  size).

**Changed for EH2** (constants + one hook):

| Constant | Value |
|---|---|
| `DEFAULT_BASE` | `https://raw.githubusercontent.com/maar-10/EasyHover2/main` |
| `SOURCE_FILE` | `/easyhover2_suite_src.txt` |
| `TOKEN_FILE` | `/easyhover2_suite_token.txt` (repo is public; token optional) |
| `STATE_FILE` | `/easyhover2_install.txt` |
| `BACKUP_ROOT` | `/easyhover2_backup` |
| `STAGE` | `.eh2new` |
| `PROTECTED` | `^/eh2_.*%.tbl$`, `^/eh2_.*%.log$`, `^/easyhover2_backup`, `^/easyhover2_install%.txt$`, `^/easyhover2_suite_src%.txt$`, `^/easyhover2_suite_token%.txt$` |

The **one behavioural change**: config-extension is made manifest-driven (§6).

### 3.2 `tools/gen_manifest.lua` (Lua generator, run headless in CraftOS-PC)
Replaces v1's `gen_manifest.js`. Emits `manifest.lua`. Shares the **exact** `Suite.checksum`
FNV-1a with the Suite (both `require` a single `fnv1a` implementation — see §7) so host/CC parity
is guaranteed by construction, not by hand. Modes: default (write), `--check` (assert the
committed manifest is in sync with the working tree), `--selftest` (print reference checksums for
`""`, `"a"`, `"hello"`). Run via CraftOS-PC headless (a `startup.lua` that runs it and writes the
manifest back to the host data dir).

### 3.3 Launchers (`launchers/`)
Thin root programs that set `package.path` and `require` an entry point:

- `launchers/fcs.lua` → installed as `/startup.lua` → `require("tools.flight")` (boot auto-run).
- `launchers/ui.lua` → installed as `/startup.lua` → `require("ui.main")` (boot auto-run).
- `launchers/calibrate.lua` → installed as `/calibrate` (FCS command) → `require("tools.calibrate")`.

### 3.4 Tests (`tests/`)
- `tests/test_suite.lua` — pure-logic units (`choosePlan`, `integrity`, `detectRole`,
  `rolePickerLayout`, `parseState`/`formatState`, `isProtected`) + FNV-1a parity assertions
  against the generator's `--selftest` reference values. Runs under the existing
  `tests/run_headless.sh`.
- `tests/suite_probe.lua` + `tests/run_suite_e2e.sh` — real headless install/update/repair/
  config-keep/detect/protect/check/prepared against a **localhost mirror** of the repo.

## 4. Role model

Two released roles now. Each role in the manifest declares: `title`, `blurb`, `status`
(`released|prepared`), `dirs` (owned — deletable on repair), `configs`, `configModule`,
`luaPath`, `entry` (human hint), and generated `files[] = {src, dst, size, sum}`.

### `fcs` — Flight computer
- **Entry points (closure roots):** `tools/flight.lua`, `tools/calibrate.lua`.
- **Launchers:** `launchers/fcs.lua` → `startup.lua`; `launchers/calibrate.lua` → `calibrate`.
- **Owned dirs:** `fcs`, `tools` (repair-scope). *(Note: repair clears these dirs; the Suite
  re-fetches exactly the closure, so tools/ files outside the closure — probes, installers — are
  intentionally **not** shipped and would be pruned. See §9 open item.)*
- **Config:** `/eh2_hw_config.tbl`; `configModule = "fcs.io.config"`.
- **`luaPath`:** `/` (modules resolve as `fcs.*` / `tools.*` from root).

### `ui` — Cockpit display
- **Entry point:** `ui/main.lua`.
- **Launcher:** `launchers/ui.lua` → `startup.lua`.
- **Owned dirs:** `ui`, plus whatever `fcs/` subdirs the closure touches (`fcs/comms`, …). Repair
  scope is the set of dirs the closure's files live under.
- **Config:** none (`configs = {}`, no `configModule`).
- **`luaPath`:** `/`.

### Role membership = dependency-closure (the one new mechanism)
Because `fcs` and `ui` **share** the `fcs/` tree (UI needs only `fcs/comms/*`, not the flight
stack), a role's file set is **not** "walk a directory." Instead the generator computes the
**transitive `require()` closure** from each role's entry points:

1. Read an entry `.lua`; scan for `require("mod.name")` (pattern
   `require%s*%(?%s*["']([%w%._%-]+)["']`).
2. Map module → path via the package.path convention: `mod.name` → `mod/name.lua`, else
   `mod/name/init.lua`. Resolve against the repo root.
3. Recurse over newly found files; union the closures of all of a role's entry points.
4. Add the role's launcher(s) and the config module (which is in the closure once
   `tools/flight.lua` uses it — see §6). Ship exactly that set.

An unresolvable `require` (names a file not in the repo) is a **hard error** in the generator —
that is a real missing dependency, surfaced at release time. CC built-ins (`fs`, `http`,
`peripheral`, `os`, `term`, `textutils`, `parallel`, …) are globals, never `require`d, so there is
no stdlib to filter. This makes role membership automatic and correct-by-construction: add a
module, and as long as something requires it, it ships — no manual list to drift.

The closure derivation is a **pure function** (`entryPaths, readFile → sorted file list`) and is
unit-tested independently of the filesystem.

## 5. Manifest schema (`manifest.lua`)

Generated data table (parsed with `textutils.unserialise` in an empty env — inert). Shape carried
from v1, plus `configModule`:

```lua
{
  ["base"]    = "https://raw.githubusercontent.com/maar-10/EasyHover2/main",
  ["version"] = "<12-hex digest of every shipped file's dst:sum:size>",
  ["schema"]  = 1,
  ["updater"] = { ["size"] = <n>, ["sum"] = "<fnv>" },   -- easyhover2_suite.lua itself
  ["roles"] = {
    ["fcs"] = {
      ["title"] = "Flight computer",
      ["blurb"] = "…", ["status"] = "released",
      ["dirs"] = { "fcs", "tools" },
      ["configs"] = { "/eh2_hw_config.tbl" },
      ["configModule"] = "fcs.io.config",
      ["luaPath"] = "/",
      ["entry"] = "startup.lua",
      ["files"] = { { ["src"]="…", ["dst"]="…", ["size"]=<n>, ["sum"]="<fnv>" }, … },
    },
    ["ui"] = { … ["configs"] = {}, (no configModule) … },
  },
}
```

`version` moves only when shipped bytes move; `schema` bumps only on an incompatible config
layout change (not now).

## 6. Config-extension, made manifest-driven

v1's `extendConfig` hardcoded `require("lib.config")`. To keep the Suite generic (requirement 1),
the **manifest declares `configModule` per role** and the Suite `require`s that, expecting the
same three-function contract v1 used:

- `Config.load(path) -> cfg, existed, err` — read + parse (never throws).
- `Config.withDefaults(cfg) -> cfg` — deep-merge saved values over fresh defaults (added fields
  appear; set values kept; lists replaced).
- `Config.save(path, cfg) -> ok, err` — serialise back.

`Suite.extendConfig` (behaviour unchanged from v1): back up the config, `load`; if it parses,
`save(withDefaults(cfg))` → **extended**; if it will not parse, it is already backed up →
rewrite defaults → **quarantined**; absent → left for first run. A role with no `configModule`
(UI) skips extension entirely.

**New module `fcs/io/config.lua`** provides that contract for FCS, wrapping the existing
`fcs/io/hwconfig.lua` (`merge`, `defaults`) and the file IO currently inlined in
`tools/flight.lua`'s `loadConfig`. `tools/flight.lua` and `tools/calibrate.lua` are refactored to
use `fcs.io.config.load/withDefaults` (removing the duplicated inline read+merge), which also
brings the module into the FCS closure naturally. This is a small, tested, in-scope improvement to
code the Suite touches; it does not change runtime behaviour (same merge semantics, same file
path).

## 7. FNV-1a parity

Both the Suite and the generator use **one** implementation. Extract `fnv1a(str) -> hex` into a
tiny module the Suite embeds (it must be self-contained for `wget run`, so the Suite keeps its own
copy as `Suite.checksum`) and the generator `require`s a `tools/fnv1a.lua` that is byte-identical
in algorithm. Parity is enforced two ways: (a) the generator's `--selftest` prints reference
checksums which `tests/test_suite.lua` asserts against the Suite's `Suite.checksum`; (b) the e2e
install verifies every fetched file's `sum` against the manifest — a divergence would fail the
whole install, not slip through.

## 8. Trust model

HTTPS to a pinned `raw.githubusercontent.com` URL is the trust root, exactly as for `wget run`.
FNV-1a + size answer "did this change / did it arrive intact" — not a signature; no defence
against a hostile GitHub. EasyHover2 is a **public** repo, so `wget run` works with no token;
`TOKEN_FILE` is carried over only as a fallback for a future private mirror/fork.

## 9. Testing

- **Unit** (`tests/test_suite.lua`, under `tests/run_headless.sh`): `choosePlan` truth table;
  `integrity` (missing/corrupt/ok via injected `read`); `detectRole` (subset-role tie-break,
  no-record case); `rolePickerLayout` at basic + advanced terminal sizes; `parseState` tolerance
  of a mangled record; `isProtected` for every EH2 config/pattern; **closure derivation** (pure,
  injected `readFile`); **FNV parity** vs generator `--selftest`; `fcs/io/config.lua`
  load/withDefaults/save round-trip incl. additive-merge and unparseable-quarantine.
- **e2e** (`tests/run_suite_e2e.sh` + `tests/suite_probe.lua`): serve the repo on localhost,
  point the Suite at it via `_src.txt`, and run real phases — `install`, `current`, `configkeep`
  (a pilot value survives an update), `repair` (corrupt a file → clean reinstall, config kept),
  `badconfig` (unparseable config quarantined + backed up), `detect` (missing install record →
  role detected from disk), `protect` (a manifest naming a protected path is refused by `guard`),
  `check` (dry run writes nothing), `prepared` (a reserved role installs nothing), plus a fresh
  install of the **other** released role. Probe drives via `--script` (never overwriting its own
  `/startup.lua`) and asserts each phase into `pc_result.txt`.
- **e2e server:** python `http.server` is primary (verified available: Python 3.14 + curl). The
  harness is **server-agnostic with a fallback**: it tries python, and if absent falls back to
  another static file server (e.g. a minimal one), selecting whatever is on the machine so the e2e
  runs without python too.
- **Generator sync guard:** `tools/gen_manifest.lua --check` asserts the committed `manifest.lua`
  matches the working tree, so a forgotten regenerate is caught (wired into the suite test run).

## 10. Non-goals / deferred

- **NAV role** — added to the generator's role table + a `nav/` closure when `nav/` exists; no
  Suite change.
- **Suite UI** — §16 defers it; the Suite is terminal-driven (role picker only).
- **Config schema migrator** — §15 additive-only now; `schema = 1`.
- **Basalt** — not shipped; EH2 cockpit is the custom toolkit.

## 11. Open items / risks

1. **FCS owns `tools/`, but `tools/` also holds non-shipped programs** (probes, `install_*`,
   `fix_yaw_sign`). Because repair clears owned dirs and `pruneRole` drops unlisted files, those
   dev-only tools would be removed from an FCS computer. That is **correct** for a pilot's
   machine (they are not part of the product) — but worth a note in the plan so the closure roots
   are exactly `flight.lua` + `calibrate.lua` and nothing accidentally depends on a probe.
2. **`require` scanner limits** — it matches literal `require("string")` calls. Dynamic requires
   (computed names) are not used in this codebase; the plan should assert (grep) that no shipped
   entry uses a non-literal `require`, so the closure is complete.
3. **Root-file collision** — both `fcs` and `ui` install a `/startup.lua`. That is fine (a
   computer is one role), and switching roles is a role-change that clears the old role's dirs
   first; the shared root `startup.lua` is overwritten by the new role's launcher.
4. **`hover_test.lua` in the FCS closure** — `tools/flight.lua` requires `tools.hover_test`
   (`buildLoop`). It ships as part of FCS by closure, which is correct.
```
