# EasyHover 2 Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `easyhover2_suite.lua` — a run-from-GitHub installer/updater/repairer with a custom UI that installs any EasyHover 2 role (fcs/ui) plus the shared debug tools, keeping configs sacred.

**Architecture:** Retarget the proven, tested EasyHover 1 Suite (`../EasyHover/easyhover_suite.lua`) to EH2: same integrity engine (FNV-1a checksum-every-run, all-or-nothing staging, `guard()`-protected config, cache-busting, independent self-update), with EH2 constants, a manifest-driven config hook, per-role dependency-closure membership, single-latest backups, and an embedded pure-CC UI. A Lua manifest generator run headless in CraftOS-PC produces `manifest.lua`.

**Tech Stack:** Lua 5.1 (CC:Tweaked), CraftOS-PC console (headless tests), python `http.server` (e2e mirror), git.

## Global Constraints

- Target **Minecraft 1.21.1**, CC:Tweaked. Lua 5.1 semantics (`bit32`, no integer type, `#` on tables).
- The Suite must be a **single self-contained file** (`wget run` fetches one file) — no `require` of project modules from within `easyhover2_suite.lua`; it embeds its own FNV-1a copy.
- **Never** modify `tools/flight.lua`, `tools/calibrate.lua`, or anything under `fcs/` except the **new** `fcs/io/config.lua`. The stable-hover control stack is off-limits.
- `manifest.lua` is **data only** (`textutils.unserialise` in an empty env) — no functions, no `return`.
- FNV-1a 32-bit over **LF-normalised** bytes, lower-case hex, must agree byte-for-byte between the Suite and the generator. Reference values: `fnv1a("")=811c9dc5`, `fnv1a("a")=e40c292c`, `fnv1a("hello")=4f9f2cab`.
- Config is **PROTECTED**: never deleted or overwritten by a release write, in any operation. Backup folder holds **exactly one** (latest) backup.
- Base URL: `https://raw.githubusercontent.com/maar-10/EasyHover2/main` (public repo).
- All new Lua must pass `tests/run_headless.sh` (headless CraftOS-PC) and `loadfile` clean.
- Reference source of truth for the engine: `../EasyHover/easyhover_suite.lua` (read it; do not guess its behaviour).

---

## File structure

**Create:**
- `tools/fnv1a.lua` — shared FNV-1a module (generator requires it; Suite embeds an identical copy).
- `fcs/io/config.lua` — standalone config module (load/withDefaults/save over `hwconfig`); Suite-only.
- `tools/closure.lua` — pure `require()` dependency-closure resolver (generator uses it).
- `tools/gen_manifest.lua` — Lua manifest generator, run headless in CraftOS-PC.
- `easyhover2_suite.lua` — the Suite (engine + UI), single file.
- `launchers/fcs.lua`, `launchers/ui.lua`, `launchers/flight.lua`, `launchers/cockpit.lua`, `launchers/calibrate.lua`, `launchers/hovertest.lua`, `launchers/probe.lua`, `launchers/probemodem.lua`, `launchers/probebatch.lua` — thin root launchers.
- `manifest.lua` — generated (committed).
- `tests/test_suite.lua` — Suite/config/closure/UI unit tests (runs under `run_headless.sh`).
- `tests/suite_probe.lua` — e2e probe driven headless.
- `tests/run_suite_e2e.sh` — e2e harness (python + fallback).

**Modify:**
- `tests/run_headless.sh` — ensure it copies `easyhover2_suite.lua`, `manifest.lua`, `launchers/`, `tools/`, and runs `tests/test_suite.lua`.

**Delete:**
- `tools/install_hovertest.lua`, `tools/install_probe.lua` — obsoleted by the Suite.

---

## Phase 1 — Shared primitives (FNV-1a, config module)

### Task 1: `tools/fnv1a.lua` shared checksum

**Files:**
- Create: `tools/fnv1a.lua`
- Test: `tests/test_suite.lua` (new file, first cases)

**Interfaces:**
- Produces: `require("tools.fnv1a")(str) -> string` (8-char lower-case hex).

- [ ] **Step 1: Write the failing test** — create `tests/test_suite.lua`:

```lua
-- EasyHover 2 Suite unit tests. Run under tests/run_headless.sh.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")   -- existing project test framework

local fnv1a = require("tools.fnv1a")

t.test("fnv1a reference vectors", function()
  t.eq(fnv1a(""), "811c9dc5")
  t.eq(fnv1a("a"), "e40c292c")
  t.eq(fnv1a("hello"), "4f9f2cab")
end)
```

Check `tests/framework.lua` first for the actual assertion API (`t.test`, `t.eq`/`t.equals`/`assert_eq`); use whatever it exports. If the framework's names differ, adapt these calls consistently across all tasks.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `tools.fnv1a` not found.

- [ ] **Step 3: Implement `tools/fnv1a.lua`** (ported verbatim from the v1 suite's `checksum`, as a module):

```lua
-- FNV-1a, 32-bit, lower-case hex, over the string's bytes (caller LF-normalises).
-- Shared by easyhover2_suite.lua (which embeds an identical copy) and tools/gen_manifest.lua.
-- 32-bit multiply split into 16-bit halves: the naive product reaches ~7.2e16, past the 2^53
-- exact-integer limit of a Lua double, and would silently lose precision.
local FNV_PRIME, FNV_OFFSET = 16777619, 2166136261

local function fnv1a(s)
  local h, n, i = FNV_OFFSET, #s, 1
  while i <= n do
    local j = i + 255
    if j > n then j = n end
    local b = { string.byte(s, i, j) }
    for k = 1, #b do
      h = bit32.bxor(h, b[k])
      local lo = h % 65536
      local hi = (h - lo) / 65536
      h = ((hi * FNV_PRIME % 65536) * 65536 + lo * FNV_PRIME) % 4294967296
    end
    i = j + 1
  end
  return ("%08x"):format(h)
end

return fnv1a
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS (fnv1a reference vectors).

- [ ] **Step 5: Wire `tests/test_suite.lua` into the runner.** `tests/run_headless.sh` uses an **explicit** `suites = { … }` list and copies only `fcs/tools/ui/tests` into `computer/0`. Make these exact edits:
  - Append `"tests.test_suite"` to the `suites` array.
  - After the `cp -r "$ROOT/ui" "$COMP/"` block, add copies for the suite artifacts (guarded, since they don't exist until later tasks):
    ```bash
    if [ -d "$ROOT/launchers" ]; then cp -r "$ROOT/launchers" "$COMP/"; fi
    if [ -f "$ROOT/easyhover2_suite.lua" ]; then cp "$ROOT/easyhover2_suite.lua" "$COMP/"; fi
    if [ -f "$ROOT/manifest.lua" ]; then cp "$ROOT/manifest.lua" "$COMP/"; fi
    ```
  Re-run `bash tests/run_headless.sh` and confirm the new test is counted.

- [ ] **Step 6: Commit**

```bash
git add tools/fnv1a.lua tests/test_suite.lua tests/run_headless.sh
git commit -m "feat(suite): shared FNV-1a checksum module + first suite test"
```

---

### Task 2: `fcs/io/config.lua` standalone config module

**Files:**
- Create: `fcs/io/config.lua`
- Test: `tests/test_suite.lua`

**Interfaces:**
- Consumes: `require("fcs.io.hwconfig")` (`.defaults()`, `.merge(saved, defaults)`).
- Produces:
  - `Config.load(path) -> cfg|nil, existed(bool), err|nil`
  - `Config.withDefaults(cfg) -> cfg`
  - `Config.save(path, cfg) -> ok(bool), err|nil`

- [ ] **Step 1: Write the failing tests** (append to `tests/test_suite.lua`):

```lua
local Config = require("fcs.io.config")

t.test("config withDefaults is additive over hwconfig", function()
  local merged = Config.withDefaults({ bindings = { signPitch = -1 } })
  t.eq(merged.bindings.signPitch, -1)      -- kept
  t.eq(merged.bindings.signRoll, 1)        -- filled from defaults
  t.eq(merged.fuelRelay, false)            -- filled from defaults
end)

t.test("config save then load round-trips", function()
  local path = "/eh2_test_cfg.tbl"
  if fs.exists(path) then fs.delete(path) end
  local ok = Config.save(path, { bindings = { yawBaseline = 3 } })
  t.eq(ok, true)
  local cfg, existed, err = Config.load(path)
  t.eq(existed, true); t.eq(err, nil); t.eq(cfg.bindings.yawBaseline, 3)
  fs.delete(path)
end)

t.test("config load reports absent + unparseable distinctly", function()
  local cfg, existed = Config.load("/eh2_nope.tbl")
  t.eq(existed, false)
  local bad = "/eh2_bad_cfg.tbl"
  local f = fs.open(bad, "w"); f.write("this is not = a table {{{"); f.close()
  local c2, ex2, err2 = Config.load(bad)
  t.eq(ex2, true)          -- the file exists
  t.eq(err2 ~= nil, true)  -- but did not parse
  fs.delete(bad)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `fcs.io.config` not found.

- [ ] **Step 3: Implement `fcs/io/config.lua`:**

```lua
-- Standalone config module for the EasyHover 2 Suite's config-extension.
-- Wraps fcs/io/hwconfig.lua and mirrors tools/calibrate.lua's atomic save.
-- USED ONLY BY THE SUITE. tools/flight.lua and tools/calibrate.lua are unchanged.
local hwconfig = require("fcs.io.hwconfig")
local M = {}

-- Read + unserialise the SAVED table (pre-merge). Never throws.
-- Returns cfg|nil, existed, err. existed=true with err set means present-but-unparseable.
function M.load(path)
  if not fs.exists(path) or fs.isDir(path) then return nil, false, nil end
  local f = fs.open(path, "r")
  if not f then return nil, true, "could not open" end
  local raw = f.readAll(); f.close()
  local cfg = textutils.unserialise(raw or "")
  if type(cfg) ~= "table" then return nil, true, "not a table" end
  return cfg, true, nil
end

-- Additive: saved values over fresh defaults (deep-merged by hwconfig).
function M.withDefaults(cfg)
  return hwconfig.merge(cfg or {}, hwconfig.defaults())
end

-- Atomic write: tmp + move (mirrors calibrate.lua's saveConfig).
function M.save(path, cfg)
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "could not open tmp" end
  f.write(textutils.serialise(cfg)); f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true, nil
end

return M
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS (3 config tests).

- [ ] **Step 5: Commit**

```bash
git add fcs/io/config.lua tests/test_suite.lua
git commit -m "feat(suite): standalone fcs/io/config.lua for manifest-driven config-extension"
```

---

## Phase 2 — Closure resolver & generator

### Task 3: `tools/closure.lua` dependency-closure resolver (pure)

**Files:**
- Create: `tools/closure.lua`
- Test: `tests/test_suite.lua`

**Interfaces:**
- Produces: `closure.resolve(roots, readFile) -> sortedFileList, err`
  - `roots`: array of repo-relative `.lua` paths (e.g. `"tools/flight.lua"`).
  - `readFile(path) -> string|nil`: injected reader (real one reads the repo).
  - Returns a sorted array of unique repo-relative paths (roots + all transitively `require`d files), or `nil, errmsg` if a `require` cannot be resolved to a repo file.

- [ ] **Step 1: Write the failing tests** (append):

```lua
local closure = require("tools.closure")

t.test("closure follows literal require() and dedupes", function()
  local files = {
    ["a.lua"]     = 'local b = require("b")\nlocal c = require("pkg.c")',
    ["b.lua"]     = 'local c = require("pkg.c")',
    ["pkg/c.lua"] = '-- leaf, no requires',
  }
  local read = function(p) return files[p] end
  local out, err = closure.resolve({ "a.lua" }, read)
  t.eq(err, nil)
  t.eq(table.concat(out, ","), "a.lua,b.lua,pkg/c.lua")
end)

t.test("closure resolves init.lua form and unions multiple roots", function()
  local files = {
    ["app.lua"]      = 'require("mod")',
    ["mod/init.lua"] = '-- package',
    ["tool.lua"]     = 'require("mod")',
  }
  local out = closure.resolve({ "tool.lua", "app.lua" }, function(p) return files[p] end)
  t.eq(table.concat(out, ","), "app.lua,mod/init.lua,tool.lua")
end)

t.test("closure errors on unresolvable require", function()
  local read = function(p) if p == "a.lua" then return 'require("ghost")' end end
  local out, err = closure.resolve({ "a.lua" }, read)
  t.eq(out, nil)
  t.eq(err:find("ghost") ~= nil, true)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `tools.closure` not found.

- [ ] **Step 3: Implement `tools/closure.lua`:**

```lua
-- Pure require()-closure resolver for the manifest generator.
-- Maps module "a.b.c" to "a/b/c.lua" (else "a/b/c/init.lua") per the package.path convention.
local M = {}

local function moduleCandidates(mod)
  local base = mod:gsub("%.", "/")
  return { base .. ".lua", base .. "/init.lua" }
end

-- Every literal require("...") in the source. Matches inside functions and comments alike;
-- the codebase uses only literal requires (asserted by the plan's grep guard).
local function requiresOf(src)
  local mods = {}
  for m in src:gmatch('require%s*%(?%s*["\']([%w%._%-]+)["\']') do
    mods[#mods + 1] = m
  end
  return mods
end

-- roots: array of repo-relative .lua paths. read(path) -> string|nil.
-- Returns sorted unique file list, or nil, err on an unresolvable require.
function M.resolve(roots, read)
  local seen, order = {}, {}
  local stack = {}
  for i = #roots, 1, -1 do stack[#stack + 1] = roots[i] end

  while #stack > 0 do
    local path = table.remove(stack)
    if not seen[path] then
      local src = read(path)
      if src == nil then return nil, "cannot read file: " .. path end
      seen[path] = true
      order[#order + 1] = path
      for _, mod in ipairs(requiresOf(src)) do
        local resolved
        for _, cand in ipairs(moduleCandidates(mod)) do
          if read(cand) ~= nil then resolved = cand; break end
        end
        if not resolved then
          return nil, ("unresolvable require '%s' in %s"):format(mod, path)
        end
        if not seen[resolved] then stack[#stack + 1] = resolved end
      end
    end
  end

  table.sort(order)
  return order, nil
end

return M
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: PASS (3 closure tests).

- [ ] **Step 5: Add the literal-require guard.** Run this and confirm **no output** (no computed requires in shipped roots):

```bash
grep -rnE 'require\s*\(\s*[^"'\'' )]' tools/flight.lua tools/calibrate.lua tools/hover_test.lua tools/probe.lua tools/probe_modem.lua tools/probe_batch.lua ui/main.lua || echo "OK: all requires are literal"
```

Expected: `OK: all requires are literal`.

- [ ] **Step 6: Commit**

```bash
git add tools/closure.lua tests/test_suite.lua
git commit -m "feat(suite): pure require()-closure resolver for the manifest generator"
```

---

### Task 4: `launchers/*.lua` thin root programs

**Files:**
- Create: `launchers/fcs.lua`, `launchers/ui.lua`, `launchers/flight.lua`, `launchers/cockpit.lua`, `launchers/calibrate.lua`, `launchers/hovertest.lua`, `launchers/probe.lua`, `launchers/probemodem.lua`, `launchers/probebatch.lua`

**Interfaces:**
- Produces: root programs that set `package.path` and run an entry. `fcs.lua`/`ui.lua` install as `/startup.lua`; the rest as their command name.

- [ ] **Step 1: Create the launchers.** Each is one of these two shapes. Boot/app launchers (`fcs`, `ui`, `flight`, `cockpit`) require the app module (which runs on load):

```lua
-- launchers/fcs.lua  (installed as /startup.lua on the fcs role)
package.path = "/?.lua;/?/init.lua;" .. package.path
require("tools.flight")
```

```lua
-- launchers/ui.lua  (installed as /startup.lua on the ui role)
package.path = "/?.lua;/?/init.lua;" .. package.path
require("ui.main")
```

`launchers/flight.lua` = same body as `launchers/fcs.lua` (installed as `flight`).
`launchers/cockpit.lua` = same body as `launchers/ui.lua` (installed as `cockpit`).

Tool launchers require the tool module:

```lua
-- launchers/calibrate.lua  (installed as calibrate)
package.path = "/?.lua;/?/init.lua;" .. package.path
require("tools.calibrate")
```

Repeat for `hovertest` → `require("tools.hover_test")`, `probe` → `require("tools.probe")`, `probemodem` → `require("tools.probe_modem")`, `probebatch` → `require("tools.probe_batch")`.

- [ ] **Step 2: Verify each launcher is loadfile-clean.** Run:

```bash
for f in launchers/*.lua; do luac -p "$f" 2>/dev/null && echo "ok $f" || echo "CHECK $f (luac absent -> rely on CI loadfile)"; done
```

(If `luac` is absent, the e2e/loadfile check in later tasks covers this.)

- [ ] **Step 3: Commit**

```bash
git add launchers
git commit -m "feat(suite): role + tool launchers"
```

---

### Task 5: `tools/gen_manifest.lua` Lua manifest generator

**Files:**
- Create: `tools/gen_manifest.lua`
- Reference: `../EasyHover/tools/gen_manifest.js` (structure), `../EasyHover/manifest.lua` (output shape).

**Interfaces:**
- Consumes: `require("tools.fnv1a")`, `require("tools.closure")`.
- Produces: writes `manifest.lua`. Modes: default (write), `--check` (assert in sync), `--selftest` (print reference checksums).
- Manifest shape: `{ base, version, schema=1, updater={size,sum}, roles={ <role>={ title, blurb, status, dirs, configs, configModule, luaPath, entry, files={{src,dst,size,sum}} } } }`.

**Role declaration (inside the generator):**

```lua
local SHARED_DIAG = {
  { src = "launchers/calibrate.lua",  dst = "calibrate"  },
  { src = "launchers/hovertest.lua",  dst = "hovertest"  },
  { src = "launchers/probe.lua",      dst = "probe"      },
  { src = "launchers/probemodem.lua", dst = "probemodem" },
  { src = "launchers/probebatch.lua", dst = "probebatch" },
}
local CONFIG_MODULE = "fcs.io.config"
local ROLES = {
  fcs = {
    title = "Flight computer", status = "released",
    blurb = "Thrusters, sensors, pilot input, control loops. Boots the flight app.",
    configs = { "/eh2_hw_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
    startup = { src = "launchers/fcs.lua", dst = "startup.lua" },
    roots   = { { src = "launchers/flight.lua", dst = "flight" } },  -- + SHARED_DIAG + config module
  },
  ui = {
    title = "Cockpit display", status = "released",
    blurb = "Receives telemetry, renders reported state, sends commands on touch. Boots the cockpit.",
    configs = { "/eh2_hw_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
    startup = { src = "launchers/ui.lua", dst = "startup.lua" },
    roots   = { { src = "launchers/cockpit.lua", dst = "cockpit" } },
  },
}
```

- [ ] **Step 1: Implement the generator.** Key logic (write `tools/gen_manifest.lua`):
  - `readNorm(path)`: read file via `fs`, replace `\r\n` → `\n`.
  - For each role: assemble the **launcher entries** = `{ role.startup }` + `role.roots` + `SHARED_DIAG` + `{ { src = "fcs/io/config.lua", dst = "fcs/io/config.lua" } }`. The closure **roots** are the `src` of every launcher entry.
  - `closure.resolve(rootSrcs, readNorm)` → discovered files (ship with `dst = src`). **Union** them with the launcher entries (launchers ship with their declared `dst`; a launcher src that also appears in the closure keeps its launcher `dst`). Dedupe by `dst`.
  - For each shipped file: `body = readNorm(src)`, `size = #body`, `sum = fnv1a(body)`; push `{src,dst,size,sum}`; add `role..":"..dst..":"..sum..":"..size` to `digestParts`. Sort files by `dst`.
  - `dirs` = the sorted set of top-level directory segments among the role's `dst` paths that contain a `/` (e.g. `fcs`, `tools`, `ui`) — repair scope.
  - `updater = { size = #suiteBody, sum = fnv1a(suiteBody) }` from `readNorm("easyhover2_suite.lua")`.
  - `version = fnv1a(table.concat(sortedDigestParts, "|")):sub(1,12)`.
  - Serialise deterministically: reuse `textutils.serialise` is **not** stable-ordered; instead write a small deterministic emitter (sort table keys; arrays in order) matching v1's `luaValue`. Prepend the header comment (data-only warning). Write to `manifest.lua`.
  - `--selftest`: print `empty=`,`a=`,`hello=` fnv1a values and exit.
  - `--check`: build the output in memory; compare to the committed `manifest.lua` (LF-normalised); exit 0 if equal, else print "OUT OF SYNC" and set a nonzero result.

  Because CraftOS-PC has no process exit code over `--headless`, the generator writes a **result line** to `/gen_result.txt` (e.g. `WROTE <version>` / `IN SYNC` / `OUT OF SYNC` / `ERROR <msg>`) in addition to printing, so the headless harness can read the outcome.

- [ ] **Step 2: Create a headless runner** `tests/.craftos`-style driver is not needed; instead add a helper script `tools/run_gen.sh`:

```bash
#!/usr/bin/env bash
# Run tools/gen_manifest.lua headless in CraftOS-PC against the repo, writing manifest.lua back.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"
WORK="$ROOT/tests/.craftos/gen"; DATA="$WORK/data"; C0="$DATA/computer/0"
rm -rf "$WORK"; mkdir -p "$C0"
cp -r "$ROOT"/{tools,fcs,ui,launchers} "$C0"/ 2>/dev/null
[ -f "$ROOT/easyhover2_suite.lua" ] && cp "$ROOT/easyhover2_suite.lua" "$C0"/
[ -f "$ROOT/manifest.lua" ] && cp "$ROOT/manifest.lua" "$C0"/
cat > "$C0/startup.lua" <<'LUA'
package.path = "/?.lua;/?/init.lua;" .. package.path
local ok, err = pcall(function() shell.run("tools/gen_manifest.lua", table.unpack({...})) end)
if not ok then local f=fs.open("/gen_result.txt","w"); f.write("ERROR "..tostring(err)); f.close() end
os.shutdown()
LUA
ARGS="${*:-}"
# pass args by writing them into a file the generator reads, or via shell.run above
timeout 60 "$CRAFTOS" --headless -d "$DATA" >/dev/null 2>&1 || true
[ -f "$C0/manifest.lua" ] && cp "$C0/manifest.lua" "$ROOT/manifest.lua"
[ -f "$C0/gen_result.txt" ] && cat "$C0/gen_result.txt" && echo ""
```

(Adjust arg passing to match how `gen_manifest.lua` reads its mode — via `{...}` in a `startup.lua`, or a `/gen_args.txt`. Keep it simple: default run writes the manifest.)

- [ ] **Step 3: Add generator unit tests** (append to `tests/test_suite.lua`) for the pure pieces you can test without the filesystem — e.g. the deterministic serialiser and the `dirs` derivation — by factoring them into small local functions exposed on a `M` table when `_G.EH2_GEN_TEST` is set, mirroring how the suite exposes pure functions. Assert: serialising `{b=2,a=1}` yields keys in sorted order; `dirs` of `{"fcs/x.lua","tools/y.lua","startup.lua"}` = `{"fcs","tools"}`.

- [ ] **Step 4: Generate the manifest and verify parity.** Run:

```bash
bash tools/run_gen.sh
```

Expected: prints `WROTE <version>`, and `manifest.lua` exists with `roles.fcs`, `roles.ui`, `updater`, `version`. Open it and sanity-check that `ui` ships `ui/main.lua` and `fcs` ships `tools/flight.lua`, both ship the diagnostic commands, and neither ships `tools/install_*` or `fix_yaw_sign`.

- [ ] **Step 5: Commit** (manifest committed in Task 8 after the suite exists so `updater` is real; here commit the generator + tests):

```bash
git add tools/gen_manifest.lua tools/run_gen.sh tests/test_suite.lua
git commit -m "feat(suite): Lua manifest generator (closure-driven) + run_gen headless driver"
```

---

## Phase 3 — The Suite (engine port + behavioural deltas)

> The Suite is a **port** of `../EasyHover/easyhover_suite.lua`. Task 6 copies it and retargets constants (no behaviour change). Tasks 7–9 each change ONE behaviour with its own test. Read the v1 file in full before starting.

### Task 6: Port the engine with EH2 constants

**Files:**
- Create: `easyhover2_suite.lua` (from `../EasyHover/easyhover_suite.lua`)
- Test: `tests/test_suite.lua`

- [ ] **Step 1: Copy and retarget.** Copy `../EasyHover/easyhover_suite.lua` to `easyhover2_suite.lua`. Apply these exact constant changes:
  - `DEFAULT_BASE` → `"https://raw.githubusercontent.com/maar-10/EasyHover2/main"`
  - `SOURCE_FILE` → `"/easyhover2_suite_src.txt"`
  - `TOKEN_FILE` → `"/easyhover2_suite_token.txt"`
  - `STATE_FILE` → `"/easyhover2_install.txt"`
  - `BACKUP_ROOT` → `"/easyhover2_backup"`
  - `STAGE` → `".eh2new"`
  - `PROTECTED` → exactly:
    ```lua
    local PROTECTED = {
      "^/eh2_.*%.tbl$",
      "^/eh2_.*%.log$",
      "^/easyhover2_backup",
      "^/easyhover2_install%.txt$",
      "^/easyhover2_suite_src%.txt$",
      "^/easyhover2_suite_token%.txt$",
    }
    ```
  - Rename the run guard global `_G.EASYHOVER_SUITE_NO_RUN` → `_G.EH2_SUITE_NO_RUN`.
  - Update the header comment block and `--help` text: program name `easyhover2_suite.lua`, EH2 URLs, mention the config file `/eh2_hw_config.tbl`.
  - Leave the FNV-1a `Suite.checksum` inline copy as-is (it must match `tools/fnv1a.lua` — it does; same source).

- [ ] **Step 2: Write parity + retarget tests** (append):

```lua
_G.EH2_SUITE_NO_RUN = true
local Suite = require("easyhover2_suite")

t.test("suite checksum matches shared fnv1a", function()
  t.eq(Suite.checksum("hello"), fnv1a("hello"))
  t.eq(Suite.checksum(""), "811c9dc5")
end)

t.test("isProtected covers EH2 config + suite files", function()
  t.eq(Suite.isProtected("/eh2_hw_config.tbl"), true)
  t.eq(Suite.isProtected("/easyhover2_install.txt"), true)
  t.eq(Suite.isProtected("/easyhover2_backup/x"), true)
  t.eq(Suite.isProtected("/fcs/io/config.lua"), false)  -- code is not protected
end)

t.test("choosePlan truth table (carried from v1)", function()
  t.eq(Suite.choosePlan({ anyInstall = false }), "install")
  t.eq(Suite.choosePlan({ anyInstall = true, forceRepair = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, noRecord = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = true, mismatched = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = true, mismatched = false }), "current")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = false }), "update")
end)
```

Note: `require("easyhover2_suite")` works because the file `return`s `Suite` and, with `_G.EH2_SUITE_NO_RUN` set, does not run `main`. The test harness must copy `easyhover2_suite.lua` into the computer root (see Task 10 harness note; for `run_headless.sh` add it to the copy list).

- [ ] **Step 3: Confirm `run_headless.sh` copies the suite.** The guarded copies for `easyhover2_suite.lua`/`launchers/`/`manifest.lua` were added in Task 1 Step 5; now that `easyhover2_suite.lua` exists they take effect. Re-run and confirm the suite tests are counted (not skipped as a load failure).

- [ ] **Step 4: Run**

Run: `bash tests/run_headless.sh`
Expected: PASS (checksum/isProtected/choosePlan).

- [ ] **Step 5: Commit**

```bash
git add easyhover2_suite.lua tests/test_suite.lua tests/run_headless.sh
git commit -m "feat(suite): port EasyHover 1 suite engine, retargeted to EH2 constants"
```

---

### Task 7: `detectRole` — startup-launcher primary, unique-file fallback

**Files:**
- Modify: `easyhover2_suite.lua` (`Suite.detectRole`)
- Test: `tests/test_suite.lua`

**Interfaces:**
- Produces: `Suite.detectRole(manifest, exists, readFile) -> role|nil, why`
  - `exists(path)->bool`, `readFile(path)->string|nil` injected.
  - Primary: `/startup.lua` size+sum vs each role's startup-launcher `files[]` entry (the one with `dst == "startup.lua"`). Fallback: count each role's **unique** files present.

- [ ] **Step 1: Write the failing tests** (append). Build a tiny fake manifest inline:

```lua
local function fakeManifest()
  return { roles = {
    fcs = { status="released", files = {
      { dst="startup.lua", size=3, sum=Suite.checksum("fcs") },
      { dst="tools/flight.lua", size=1, sum="x" },
      { dst="fcs/io/backend.lua", size=1, sum="y" },
    }},
    ui = { status="released", files = {
      { dst="startup.lua", size=2, sum=Suite.checksum("ui") },
      { dst="ui/main.lua", size=1, sum="z" },
      { dst="fcs/io/backend.lua", size=1, sum="y" },
    }},
  }}
end

t.test("detectRole keys on the installed startup launcher", function()
  local m = fakeManifest()
  local disk = { ["/startup.lua"] = "ui" }  -- matches ui's startup sum
  local exists = function(p) return disk[p] ~= nil end
  local read = function(p) return disk[p] end
  local role = Suite.detectRole(m, exists, read)
  t.eq(role, "ui")
end)

t.test("detectRole falls back to unique files when startup is missing", function()
  local m = fakeManifest()
  local disk = { ["/tools/flight.lua"] = "a", ["/fcs/io/backend.lua"] = "b" }  -- fcs-unique present
  local exists = function(p) return disk[p] ~= nil end
  local read = function(p) return disk[p] end
  local role = Suite.detectRole(m, exists, read)
  t.eq(role, "fcs")
end)
```

- [ ] **Step 2: Run to verify it fails** (v1's `detectRole` has signature `(manifest, exists)` and counts all files — the startup-sum test fails).

Run: `bash tests/run_headless.sh`
Expected: FAIL.

- [ ] **Step 3: Replace `Suite.detectRole`** with:

```lua
-- Identify the installed role. Primary signal: the installed /startup.lua matches exactly one
-- role's startup launcher (size+sum). Fallback: the role with the most of its UNIQUE files
-- present (files whose dst appears in only one role).
function Suite.detectRole(manifest, exists, read)
  exists = exists or function(p) return fs.exists(p) and not fs.isDir(p) end
  read = read or function(p)
    if not fs.exists(p) or fs.isDir(p) then return nil end
    local f = fs.open(p, "r"); local s = f.readAll(); f.close(); return s
  end

  -- Primary: startup.lua fingerprint.
  local startupBody = read("/startup.lua")
  if startupBody then
    local size, sum = #startupBody, Suite.checksum(startupBody)
    for roleName, spec in pairs(manifest.roles) do
      if spec.status == "released" then
        for _, e in ipairs(spec.files) do
          if e.dst == "startup.lua" and e.size == size and e.sum == sum then
            return roleName, "startup"
          end
        end
      end
    end
  end

  -- Fallback: unique-file count. Build dst -> #roles-owning.
  local owners = {}
  for _, spec in pairs(manifest.roles) do
    if spec.status == "released" then
      for _, e in ipairs(spec.files) do owners[e.dst] = (owners[e.dst] or 0) + 1 end
    end
  end
  local best, bestScore = nil, 0
  for roleName, spec in pairs(manifest.roles) do
    if spec.status == "released" then
      local score = 0
      for _, e in ipairs(spec.files) do
        if owners[e.dst] == 1 and exists("/" .. e.dst) then score = score + 1 end
      end
      if score > bestScore then best, bestScore = roleName, score end
    end
  end
  if bestScore == 0 then return nil, "none" end
  return best, "unique-files"
end
```

- [ ] **Step 4: Update the one call site** in `Suite.main` (it calls `Suite.detectRole(manifest)`) — it still works (extra args default). No change needed unless v1 passed a custom `exists`; keep as-is.

- [ ] **Step 5: Run**

Run: `bash tests/run_headless.sh`
Expected: PASS (both detectRole tests).

- [ ] **Step 6: Commit**

```bash
git add easyhover2_suite.lua tests/test_suite.lua
git commit -m "feat(suite): detectRole via installed startup launcher (roles share the product)"
```

---

### Task 8: Single-latest backup + manifest-driven config module; generate real manifest

**Files:**
- Modify: `easyhover2_suite.lua` (`backup`/`ensureBackupDir`, `Suite.extendConfig`)
- Test: `tests/test_suite.lua`
- Generate: `manifest.lua`

**Interfaces:**
- `Suite.extendConfig(spec, path, version)` requires `spec.configModule` (was hardcoded `require("lib.config")` in v1) → `require(spec.configModule)`.

- [ ] **Step 1: Write the failing tests** (append):

```lua
t.test("backup keeps exactly one (latest) copy", function()
  local root = "/easyhover2_backup"
  if fs.exists(root) then fs.delete(root) end
  local src = "/eh2_hw_config.tbl"
  local f = fs.open(src, "w"); f.write("v1"); f.close()
  Suite.backupConfig(src, "verA")     -- new API: single-latest
  f = fs.open(src, "w"); f.write("v2"); f.close()
  Suite.backupConfig(src, "verB")
  -- exactly one backup file remains, containing the latest pre-backup content ("v2")
  local names = fs.list(root)
  t.eq(#names, 1)
  local bf = fs.open(root .. "/" .. names[1], "r"); local body = bf.readAll(); bf.close()
  t.eq(body, "v2")
  fs.delete(src); fs.delete(root)
end)

t.test("extendConfig uses the manifest's configModule (additive)", function()
  local path = "/eh2_hw_config.tbl"
  local Config = require("fcs.io.config")
  Config.save(path, { bindings = { signPitch = -1 } })   -- a pilot value, missing new keys
  local spec = { configModule = "fcs.io.config", luaPath = "/" }
  local result = Suite.extendConfig(spec, path, "verX")
  t.eq(result, "extended")
  local cfg = Config.load(path)
  t.eq(cfg.bindings.signPitch, -1)      -- kept
  t.eq(cfg.bindings.signRoll, 1)        -- filled from defaults
  fs.delete(path)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `Suite.backupConfig` undefined; `extendConfig` still hardcodes `lib.config`.

- [ ] **Step 3: Implement single-latest backup.** Replace v1's `ensureBackupDir`/`backup` with a single-latest scheme and expose `Suite.backupConfig`:

```lua
-- Single-latest backup: the backup folder holds exactly one copy. Each call clears the folder
-- first, then writes the current file's bytes. Copy-never-move, so a failed run costs nothing.
function Suite.backupConfig(path, version)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  if fs.exists(BACKUP_ROOT) then fs.delete(BACKUP_ROOT) end
  fs.makeDir(BACKUP_ROOT)
  local name = path:gsub("^/", ""):gsub("/", "_")
  local target = ("%s/%s"):format(BACKUP_ROOT, name)
  local f = fs.open(path, "r"); local body = f.readAll(); f.close()
  local w = fs.open(target, "w"); w.write(body or ""); w.close()
  return target
end
```

Update every v1 caller that used `backup(cfgPath, version)` to call `Suite.backupConfig(cfgPath, version)`. Remove the now-unused `backupDir`/`backedUp`/`ensureBackupDir` accounting, or keep a simple `backedUp` list appended in `backupConfig` for the end-of-run message (`#backedUp`). Keep behaviour: configs are backed up before any touch; repair still never deletes them.

- [ ] **Step 4: Make `extendConfig` manifest-driven.** In `Suite.extendConfig`, replace the hardcoded `require("lib.config")` with `require(spec.configModule)`, and guard `if not spec.configModule then return "skipped: no config module" end`. Keep the rest of v1's logic (load → withDefaults → save; unparseable → quarantine after backup). Set `package.path` from `spec.luaPath` as v1 did.

- [ ] **Step 5: Run**

Run: `bash tests/run_headless.sh`
Expected: PASS (backup single-latest + extendConfig additive).

- [ ] **Step 6: Generate the real manifest** (now that `easyhover2_suite.lua` exists, `updater` is real):

```bash
bash tools/run_gen.sh
```

Expected: `WROTE <version>`. Verify `manifest.lua` `updater.size`/`sum` match the suite file:
```bash
grep -A2 '\["updater"\]' manifest.lua
```

- [ ] **Step 7: Commit**

```bash
git add easyhover2_suite.lua tests/test_suite.lua manifest.lua
git commit -m "feat(suite): single-latest backup + manifest-driven configModule; generate manifest"
```

---

### Task 9: Remove obsolete installers; regenerate manifest

**Files:**
- Delete: `tools/install_hovertest.lua`, `tools/install_probe.lua`
- Regenerate: `manifest.lua`

- [ ] **Step 1: Delete the obsolete installers.**

```bash
git rm tools/install_hovertest.lua tools/install_probe.lua
```

- [ ] **Step 2: Confirm nothing shipped requires them.** Run:

```bash
grep -rnE 'install_hovertest|install_probe' tools ui fcs launchers easyhover2_suite.lua || echo "OK: no references"
```

Expected: `OK: no references`.

- [ ] **Step 3: Regenerate + verify in-sync.**

```bash
bash tools/run_gen.sh
```

Expected: `WROTE <version>` (version unchanged if the installers were never shipped — they weren't, being non-roots; confirm the manifest still lists no `install_*`).

- [ ] **Step 4: Commit**

```bash
git add -A tools manifest.lua
git commit -m "chore(suite): remove install_* (obsoleted by the Suite); regenerate manifest"
```

---

## Phase 4 — Suite UI (custom pure-CC)

### Task 10: UI pure layout functions

**Files:**
- Modify: `easyhover2_suite.lua` (add a UI section with pure layout helpers on `Suite`)
- Test: `tests/test_suite.lua`

**Interfaces:**
- `Suite.uiPanels(width, height) -> { title=<rect>, status=<rect>, integrity=<rect>, actions=<rect>, diag=<rect> }` where `<rect> = {x,y,w,h}`, all within bounds, non-overlapping.
- `Suite.progressFill(done, total, barWidth) -> filledCells(int)` (0..barWidth; 0 when total==0).
- `Suite.statusColour(plan) -> colour` (`"current"`→`colours.lime`, `"update"`→`colours.yellow`, `"repair"`/`"install"`→ per spec).

- [ ] **Step 1: Write the failing tests** (append):

```lua
t.test("uiPanels fit within bounds and don't overlap", function()
  for _, sz in ipairs({ {51,19}, {39,13} }) do
    local p = Suite.uiPanels(sz[1], sz[2])
    for _, r in pairs(p) do
      t.eq(r.x >= 1 and r.y >= 1 and r.x + r.w - 1 <= sz[1] and r.y + r.h - 1 <= sz[2], true)
    end
  end
end)

t.test("progressFill is proportional and clamped", function()
  t.eq(Suite.progressFill(0, 0, 10), 0)
  t.eq(Suite.progressFill(5, 10, 10), 5)
  t.eq(Suite.progressFill(10, 10, 10), 10)
  t.eq(Suite.progressFill(99, 10, 10), 10)
end)

t.test("statusColour maps plan to colour", function()
  t.eq(Suite.statusColour("current"), colours.lime)
  t.eq(Suite.statusColour("update"), colours.yellow)
end)
```

- [ ] **Step 2: Run to verify it fails.**

Run: `bash tests/run_headless.sh`
Expected: FAIL — helpers undefined.

- [ ] **Step 3: Implement the pure helpers** in `easyhover2_suite.lua` (place near the role-picker layout). Compute panel rects from `width`/`height` with a title bar row, a status block, an integrity block, an actions row, and a diagnostics block; clamp everything to bounds. `progressFill = total > 0 and math.min(barWidth, math.floor(done / total * barWidth + 0.5)) or 0`. `statusColour` maps the four plan states.

- [ ] **Step 4: Run.**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add easyhover2_suite.lua tests/test_suite.lua
git commit -m "feat(suite): pure UI layout/geometry helpers"
```

---

### Task 11: UI rendering + event loop, with keyboard fallback

**Files:**
- Modify: `easyhover2_suite.lua` (draw functions + `Suite.runUI`; wire `Suite.main` to call it on Advanced terminals)

**Interfaces:**
- `Suite.runUI(ctx)` — draws the dashboard from a prepared `ctx` (role, versions, integrity report, plan, source) and handles clicks by invoking the same engine paths `main` already uses (install/update, verify, repair, switch, check, launch tool).
- On a Basic terminal (`not term.isColour()`), `Suite.main` uses the existing v1 keyboard flow unchanged.

- [ ] **Step 1: Implement drawing** using `term`/`paintutils`/`window`: filled background, bordered panels (box-drawing chars, pseudo-rounded corners on Advanced), the status/integrity/actions/diag content from `ctx`, and a progress bar driven by `Suite.progressFill` during work. Keep each draw function small and fed only by data (no IO inside draw).

- [ ] **Step 2: Implement the event loop** `Suite.runUI`: draw, `os.pullEvent`, on `mouse_click` hit-test the action rects (reuse `Suite.uiPanels`), run the chosen engine action, redraw. Provide a "Launch tool ▸" affordance that lists the shipped diagnostic commands (from the manifest's `files` whose `dst` has no `/`, excluding `startup.lua`) and `shell.run`s the chosen one after confirming.

- [ ] **Step 3: Gate by capability** in `Suite.main`: if `term.isColour()` and not `checkOnly`/`listOnly`, route interactive install/update/repair through `Suite.runUI`; otherwise keep the v1 keyboard flow. Both call the same underlying functions, so the engine is untouched.

- [ ] **Step 4: Manual smoke in CraftOS-PC (advanced).** Run the suite against the localhost mirror once the e2e harness (Task 12) exists, or a quick manual launch:

```bash
# quick visual smoke: run the suite in a windowed CraftOS-PC pointed at the mirror (optional, manual)
```

Since rendering can't be asserted headlessly, rely on: the pure helpers (Task 10) + the e2e install (Task 12, which drives the engine paths via `--script`, bypassing draw). Confirm `loadfile` clean:

```bash
bash tools/run_gen.sh   # also re-checks the suite loads; or add a loadfile check to run_headless
```

- [ ] **Step 5: Regenerate manifest** (suite bytes changed → `updater` changes):

```bash
bash tools/run_gen.sh
```

- [ ] **Step 6: Commit**

```bash
git add easyhover2_suite.lua manifest.lua
git commit -m "feat(suite): custom pure-CC dashboard UI with keyboard fallback"
```

---

## Phase 5 — End-to-end & integration

### Task 12: e2e harness (localhost mirror), python + fallback

**Files:**
- Create: `tests/run_suite_e2e.sh`, `tests/suite_probe.lua`
- Reference: `../EasyHover/tests/run_suite_e2e.sh`, `../EasyHover/tests/suite_probe.lua`

- [ ] **Step 1: Port `run_suite_e2e.sh`** from v1, retargeting names (`easyhover2_suite.lua`, `easyhover2_suite_src.txt`, `EASYHOVER2_E2E_*`). Server selection: prefer `python -m http.server`; if `command -v python` fails, fall back to `python3`, then to a minimal static server (`busybox httpd`/`npx http-server` if present) — probe each and use the first available; error clearly if none.

- [ ] **Step 2: Port `suite_probe.lua`** from v1, retargeting file names and the phases: `install` (fresh, sets role via a scripted role choice — write the role into `easyhover2_suite_src`'s sibling or pass the role arg), `current`, `configkeep`, `update`, `repair`, `badconfig`, `detect`, `protect`, `check`, plus a fresh install of the **other** role and a `switch` (fcs→ui) phase. Each phase writes PASS/FAIL to `pc_result.txt`.

- [ ] **Step 3: Run the e2e.**

```bash
bash tests/run_suite_e2e.sh
```

Expected: `PASS: suite e2e green`. Fix real failures (not by loosening asserts) until green.

- [ ] **Step 4: Commit**

```bash
git add tests/run_suite_e2e.sh tests/suite_probe.lua
git commit -m "test(suite): headless e2e against a localhost mirror (python + fallback)"
```

---

### Task 13: Full verification, manifest sync guard, docs

**Files:**
- Modify: `tests/run_headless.sh` (add a `gen_manifest --check` gate if practical), `docs/FCS_CORE_DESIGN.md` (§16 → "implemented"), `README`/`docs/INSTALL` note (optional)

- [ ] **Step 1: Manifest sync guard.** Add a step (in `run_headless.sh` or a dedicated `tools/run_gen.sh --check`) that runs the generator in `--check` mode and fails if `manifest.lua` is out of sync. Verify:

```bash
bash tools/run_gen.sh --check   # expect: IN SYNC
```

- [ ] **Step 2: Full suite.**

```bash
bash tests/run_headless.sh && bash tests/run_suite_e2e.sh
```

Expected: unit suite green (all prior counts + suite tests), e2e green.

- [ ] **Step 3: Update `docs/FCS_CORE_DESIGN.md` §16** to note the Suite is implemented (`easyhover2_suite.lua`, `manifest.lua`, roles fcs/ui, single-latest backup, custom UI), and that the UI-role app build-out is the next project (link the spec's §11).

- [ ] **Step 4: Commit**

```bash
git add tests/run_headless.sh docs/FCS_CORE_DESIGN.md
git commit -m "docs(suite): mark §16 implemented; wire manifest sync guard into the test run"
```

---

## Self-review checklist (run before execution)

- **Spec coverage:** engine retarget (T6), manifest-driven/no-hardcoded (T5), independent self-update (carried in T6 port — verify `selfUpdateNotice` retargeted to `easyhover2_suite.lua`), no-missed-update/checksum-every-run (T6 + T7), cache-bust (T6 port), per-role closure membership (T3/T5), all-tools-every-role (T4/T5 roots), config sacred + single-latest backup (T8), config additive/quarantine (T2/T8), custom UI (T10/T11), FNV parity (T1/T5), e2e (T12), remove install_* (T9), instrumentation noted (spec §8 — no task, by design). **UI-role app build-out is deferred (spec §11) — intentionally no task.**
- **Placeholder scan:** the generator serialiser (T5 Step 1) and the e2e probe phases (T12) are described, not fully coded, because they are direct ports of real, committed v1 files named in each task — the engineer copies the v1 file and retargets. Every *new* module (fnv1a, config, closure, launchers, detectRole, backup, UI helpers) has full code.
- **Type consistency:** `Suite.detectRole(manifest, exists, read)`, `Suite.backupConfig(path, version)`, `Suite.extendConfig(spec, path, version)` with `spec.configModule`, `closure.resolve(roots, read)`, `fnv1a(str)`, `Config.load/withDefaults/save` — used consistently across tasks.
