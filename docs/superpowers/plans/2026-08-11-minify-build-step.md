# Pre-deploy minify build step — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pre-deploy build step that minifies the app `.lua` source with luamin into a committed `dist/` tree, ship a two-channel manifest (minified default, readable `--dev`), and prove behaviour parity on the minified code — reclaiming ~175 KB on the `ui` role (612 KB → ~437 KB).

**Architecture:** A Node build tool (`tools/build.mjs`) minifies `fcs/ ui/ launchers/ tools/` → `dist/<same path>`. The existing manifest generator is extended to emit **two** manifests over the same role closure: `manifest.lua` (entries point at `dist/…`, sums over minified bytes) and `manifest-dev.lua` (entries point at source, sums over source bytes). The suite picks a channel (`--dev`/`--min`, persisted in `/eh2_channel.txt`, default `min`) and fetches the matching manifest — `Suite.performPlan` is unchanged because the manifest already carries the right `src` paths. A dist-tree CraftOS harness is the release acceptance gate.

**Tech Stack:** Node v22 + luamin 1.0.4 (Node API, CommonJS via `createRequire`); Lua 5.1 (CC:Tweaked) for the generator/suite/tests; CraftOS-PC headless for the test harnesses.

## Global Constraints

Every task's requirements implicitly include these (verbatim from the spec):

- **Minify scope:** every `.lua` under `fcs/`, `ui/`, `launchers/`, `tools/` → `dist/<same path>`. Nothing else.
- **NEVER minify** (referenced from original paths, identical bytes in both channels): `release/basalt-full.lua` (vendor-minified, pinned by the `feedback-basalt-full-build` house rule), `manifest.lua` / `manifest-dev.lua` (data), `easyhover2_suite.lua` / `easyhover2_suitex.lua` (bootstrap/trust root).
- **Tool = luamin 1.0.4 via its Node API** `require('luamin').minify(src)` — renames locals only, preserves table-constructor order (keeps `peripheral.*`/`redstone.*` and `textutils.serialise` key-order parity intact per `reference-cct-serialise-order`).
- **Default channel = minified.** `--dev` = readable escape hatch; `--min` forces back.
- **`dist/` is committed** to the repo (like `manifest.lua` today); GitHub raw serves committed files, keeping the `wget run` model.
- **Dependency install (decision made in planning):** commit `package.json` + `package-lock.json` pinning `luamin@1.0.4`; **gitignore `node_modules/`** (do NOT commit it — `dist/` is the committed artifact, Node tooling is dev-only). `build.mjs` fails with a clear "run npm install" message if luamin is unresolvable.
- **Checksums:** per-file FNV-1a 32-bit `sum` + `size` over LF-normalised bytes; top-level `version` digest per channel over its own bytes. `dst` names and role structure identical across channels; basalt entry identical across channels; each manifest keeps its own `version`.
- **Release workflow (new):** `node tools/build.mjs` → `bash tools/run_gen.sh` (both manifests) → `bash tests/run_headless.sh` (source) → `bash tests/run_headless_dist.sh` (gate, must be `OK`) → commit source + `dist/` + both manifests → `git push origin main`.
- **Configs stay sacred:** the `PROTECTED` list guarantees hold; a channel switch is a repair over identical `dst` names.

---

## File Structure

- `package.json`, `package-lock.json` — **create**. Pin `luamin@1.0.4`; declare `"type": "module"`.
- `.gitignore` — **modify**. Add `node_modules/`.
- `tools/build.mjs` — **create**. luamin minify walker; exports `build(root)` + config, CLI entry.
- `tests/build.test.mjs` — **create**. Node `--test` unit tests for `build.mjs`.
- `tools/gen_manifest.lua` — **modify**. Thread a `channel` through `buildRole`/`build`; emit both manifests; `--check` validates both.
- `tools/run_gen.sh` — **modify**. Copy `dist/` and `manifest-dev.lua` into the CraftOS data dir; copy `manifest-dev.lua` back out.
- `manifest.lua` — **regenerate** (now minified channel). `manifest-dev.lua` — **create** (generated + committed).
- `easyhover2_suite.lua` — **modify**. `CHANNEL_FILE` const + `PROTECTED` entry; `--dev`/`--min` parsing; `Suite.resolveChannel`/`Suite.manifestName`; fetch the chosen manifest.
- `tests/test_suite.lua` — **modify**. Unit tests for channel resolution + marker persistence.
- `tests/test_manifest_channels.lua` — **create**. Asserts both committed manifests are structurally parallel, basalt identical, versions diverge. Registered in `tests/run_headless.sh`'s suite list.
- `tests/run_headless_dist.sh` — **create**. Acceptance gate: suite against `dist/`.
- `docs/RELEASE.md` (or the existing runbook) — **modify/create**. New workflow.
- `.claude/…/memory/feedback-lua-project-release-workflow.md` — **modify** (add build + dist-gate steps). Path: `C:\Users\m-kri\.claude\projects\C--Users-m-kri-Claude-Code\memory\`.

---

## Task 1: Node minify build tool (`tools/build.mjs`)

**Files:**
- Create: `package.json`, `package-lock.json`, `tools/build.mjs`, `tests/build.test.mjs`
- Modify: `.gitignore`
- Test: `tests/build.test.mjs` (Node `--test`)

**Interfaces:**
- Produces: `build(root?: string) => string[]` (repo-relative paths written, sorted); throws `Error` naming the file on any luamin parse failure. Exports `MINIFY_DIRS = ["fcs","ui","launchers","tools"]`, `DIST = "dist"`. Writing `dist/<same-relative-path>` for every `.lua` under the minify dirs, LF, no BOM, no trailing newline added.

- [ ] **Step 1: Create `package.json` + install luamin (produces the lockfile)**

`package.json`:
```json
{
  "name": "easyhover2-build",
  "private": true,
  "type": "module",
  "version": "1.0.0",
  "description": "Dev-only pre-deploy minify build for EasyHover 2 (dist/ is the committed artifact).",
  "scripts": {
    "build": "node tools/build.mjs",
    "test": "node --test tests/"
  },
  "dependencies": {
    "luamin": "1.0.4"
  }
}
```
Run: `npm install` (creates `package-lock.json` + `node_modules/`). Expected: luamin 1.0.4 resolves; `node -e "require('node:module').createRequire(process.cwd()+'/x')('luamin')"` no longer errors.

- [ ] **Step 2: Add `node_modules/` to `.gitignore`**

Append under the "dev tooling" block:
```
# Node build tooling (dist/ is the committed artifact; node_modules is dev-only)
node_modules/
```
Leave `dist/` NOT ignored — it is committed.

- [ ] **Step 3: Write the failing test** (`tests/build.test.mjs`)

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "../tools/build.mjs";

function fixture(files) {
  const root = mkdtempSync(join(tmpdir(), "eh2build-"));
  for (const [rel, body] of Object.entries(files)) {
    const abs = join(root, rel);
    mkdirSync(join(abs, ".."), { recursive: true });
    writeFileSync(abs, body);
  }
  return root;
}

test("minifies each app .lua into dist/<same path>, shrinking bytes", () => {
  const root = fixture({ "fcs/a.lua": "local function add(x, y)\n  return x + y\nend\nreturn add\n" });
  const written = build(root);
  assert.deepEqual(written, ["fcs/a.lua"]);
  const out = readFileSync(join(root, "dist/fcs/a.lua"), "utf8");
  assert.ok(out.length < readFileSync(join(root, "fcs/a.lua"), "utf8").length, "minified is smaller");
  assert.ok(/return/.test(out), "still Lua");
});

test("hard-fails on an unparseable file, naming it, and writes no dist for that build", () => {
  const root = fixture({ "ui/bad.lua": "local x = = (" });
  assert.throws(() => build(root), /ui\/bad\.lua/);
});

test("is deterministic / idempotent (two builds byte-identical)", () => {
  const root = fixture({ "tools/t.lua": "local a=1 local b=2 return a+b\n" });
  build(root);
  const first = readFileSync(join(root, "dist/tools/t.lua"));
  build(root);
  const second = readFileSync(join(root, "dist/tools/t.lua"));
  assert.deepEqual(first, second);
});

test("copies through nothing outside the minify dirs (basalt/manifests untouched)", () => {
  const root = fixture({ "release/basalt-full.lua": "-- big vendor file\n", "fcs/x.lua": "return 1\n" });
  build(root);
  assert.equal(existsSync(join(root, "dist/release/basalt-full.lua")), false);
  assert.equal(existsSync(join(root, "dist/fcs/x.lua")), true);
});
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `node --test tests/build.test.mjs`
Expected: FAIL — `Cannot find module '../tools/build.mjs'`.

- [ ] **Step 5: Implement `tools/build.mjs`**

```js
#!/usr/bin/env node
// tools/build.mjs -- pre-deploy minify build. Reads every .lua under the minify dirs, runs
// luamin.minify on each, writes to dist/<same path>. HARD-FAILS the whole build if ANY file
// stops parsing (names it), and writes a fresh dist/ each run (deterministic + idempotent).
//
// dist/ is committed; in-game installs fetch dist/ over raw, so this NEVER runs in-game --
// it is a developer pre-commit step. Config lists are top-of-file so this vendors into the
// other suite repos (EasyKey, DriveByWire, ...) unchanged.
import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync, rmSync, existsSync, realpathSync } from "node:fs";
import { join, dirname, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
let luamin;
try { luamin = require("luamin"); }
catch { console.error("luamin is not installed. Run: npm install"); process.exit(1); }

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, "..");

// --- config (top-of-file so this vendors cleanly into other repos) ---
export const MINIFY_DIRS = ["fcs", "ui", "launchers", "tools"];
export const DIST = "dist";

function walkLua(absDir) {
  const out = [];
  for (const name of readdirSync(absDir)) {
    const abs = join(absDir, name);
    if (statSync(abs).isDirectory()) out.push(...walkLua(abs));
    else if (name.endsWith(".lua")) out.push(abs);
  }
  return out.sort();
}

// build(root) -> sorted array of repo-relative paths written under root/dist. Throws on parse fail.
export function build(root = REPO_ROOT) {
  const distAbs = join(root, DIST);
  if (existsSync(distAbs)) rmSync(distAbs, { recursive: true, force: true }); // fresh each run
  const written = [];
  for (const d of MINIFY_DIRS) {
    const dirAbs = join(root, d);
    if (!existsSync(dirAbs)) continue;
    for (const abs of walkLua(dirAbs)) {
      const rel = relative(root, abs).split(sep).join("/");
      const src = readFileSync(abs, "utf8");
      let min;
      try { min = luamin.minify(src); }
      catch (e) { throw new Error(`luamin failed to parse ${rel}: ${e.message}`); }
      const outAbs = join(distAbs, rel);
      mkdirSync(dirname(outAbs), { recursive: true });
      writeFileSync(outAbs, min);
      written.push(rel);
    }
  }
  return written;
}

// CLI entry (only when run directly, not when imported by the test).
const invoked = process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
if (invoked) {
  try { const w = build(); console.log(`built ${w.length} file(s) into ${DIST}/`); }
  catch (e) { console.error(e.message); process.exit(1); }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `node --test tests/build.test.mjs`
Expected: PASS (4 tests). Then `node tools/build.mjs` and confirm `dist/fcs`, `dist/ui`, `dist/launchers`, `dist/tools` exist and are smaller than source.

- [ ] **Step 7: Commit** (source only; `dist/` is committed in Task 5 with the manifests)

```bash
git add package.json package-lock.json .gitignore tools/build.mjs tests/build.test.mjs
git commit -m "$(cat <<'EOF'
feat(build): add luamin pre-deploy minify tool (tools/build.mjs)

Walks fcs/ ui/ launchers/ tools/, luamin.minify each .lua into dist/<same
path>, hard-fails naming any file that stops parsing, deterministic/idempotent.
luamin pinned 1.0.4 (Node API via createRequire); node_modules gitignored --
dist/ is the committed artifact, the tool is dev-only. Node --test unit tests
cover minify, parse-fail, idempotence, and copy-through scope.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Two-channel manifest generator (`tools/gen_manifest.lua` + `tools/run_gen.sh`)

**Files:**
- Modify: `tools/gen_manifest.lua` (thread `channel`; emit both; `--check` both)
- Modify: `tools/run_gen.sh` (stage `dist/` + `manifest-dev.lua` in/out)
- Create: `tests/test_manifest_channels.lua`
- Modify: `tests/run_headless.sh` (add `tests.test_manifest_channels` to the suite list)

**Interfaces:**
- Consumes: `dist/` produced by Task 1's `build()`.
- Produces: `manifest.lua` (min channel: minifiable entry `src` = `dist/<path>`, sums over minified bytes) and `manifest-dev.lua` (dev channel: `src` = source path, sums over source bytes). Both share `dst` names, role structure, and the basalt entry; each has its own `version`. `tools/run_gen.sh --check` exits non-zero if either drifts.

- [ ] **Step 1: Write the failing test** (`tests/test_manifest_channels.lua`)

```lua
-- Both committed manifests describe the SAME roles/dst structure over the SAME closure, differ
-- ONLY in each file entry's src (dist/ vs source) + sums, and carry DIFFERENT version digests.
-- The basalt entry (release/basalt-full.lua, never minified) is byte-identical across channels.
local t = require("tests.framework")

local function load(path)
  local f = fs.open(path, "r"); if not f then error("missing " .. path) end
  local body = f.readAll(); f.close()
  return textutils.unserialise(body)
end

t.test("manifest.lua (min) and manifest-dev.lua (dev) are parallel; basalt identical; versions differ", function()
  local min = load("/manifest.lua")
  local dev = load("/manifest-dev.lua")
  t.eq(type(min), "table"); t.eq(type(dev), "table")
  t.eq(min.version ~= dev.version, true, "each channel has its own version digest")
  t.eq(min.basalt.sum, dev.basalt.sum, "basalt bytes identical across channels")
  t.eq(min.updater.sum, dev.updater.sum, "suite (updater) identical across channels")
  for role, mrole in pairs(min.roles) do
    local drole = dev.roles[role]
    t.eq(type(drole), "table", "dev manifest also has role " .. role)
    t.eq(#mrole.files, #drole.files, "same file count for " .. role)
    for i, mf in ipairs(mrole.files) do
      local df = drole.files[i]
      t.eq(mf.dst, df.dst, "same dst[" .. i .. "] in " .. role)
      if mf.dst == "basalt-full.lua" then
        t.eq(mf.src, df.src, "basalt src identical")
        t.eq(mf.src, "release/basalt-full.lua", "basalt src stays source in both channels")
      else
        t.eq(mf.src:sub(1, 5), "dist/", "min channel " .. role .. " file points into dist/: " .. mf.src)
        t.eq(df.src:sub(1, 5) ~= "dist/", true, "dev channel points at source: " .. df.src)
      end
    end
  end
end)
```

- [ ] **Step 2: Register the new test + run to verify it fails**

Add `"tests.test_manifest_channels"` to the `suites` list in `tests/run_headless.sh` (the big brace list, near the end alongside `"tests.test_suite"`).
Run: `bash tests/run_headless.sh`
Expected: FAIL — `missing /manifest-dev.lua` (it does not exist yet).

- [ ] **Step 3: Thread a `channel` through `gen_manifest.lua`**

After the `REPO`/`SHARED_DIAG` block (top of file), add the channel path mapper:
```lua
-- Which source files are minified into dist/ (mirror of tools/build.mjs MINIFY_DIRS).
local MINIFY_PREFIXES = { "fcs/", "ui/", "launchers/", "tools/" }
local function isMinifiable(src)
  if not src:match("%.lua$") then return false end
  for _, p in ipairs(MINIFY_PREFIXES) do
    if src:sub(1, #p) == p then return true end
  end
  return false
end
-- For a channel ("min"|"dev") return (manifestSrc, readPath) for a source path. In the min
-- channel a minifiable file is described AND read from dist/; everything else (basalt, config
-- data) is identical to dev.
local function channelPaths(src, channel)
  if channel == "min" and isMinifiable(src) then
    return "dist/" .. src, "dist/" .. src
  end
  return src, src
end
```

In `buildRole(roleName, spec)`, add a `channel` parameter and use the mapper for BOTH the discovered-files loop and the `extraFiles` loop:
```lua
local function buildRole(roleName, spec, channel)
  ...
  for _, src in ipairs(discovered) do
    local manifestSrc, readPath = channelPaths(src, channel)
    local body = readNorm(readPath)
    if body == nil then return nil, ("role %s: cannot read file: %s (did you run `node tools/build.mjs`?)"):format(roleName, readPath) end
    local dst = srcToDst[src] or src
    local size, sum = #body, fnv1a(body)
    files[#files + 1] = { src = manifestSrc, dst = dst, size = size, sum = sum }
    digestParts[#digestParts + 1] = roleName .. ":" .. dst .. ":" .. sum .. ":" .. size
  end
  for _, e in ipairs(spec.extraFiles or {}) do
    local manifestSrc, readPath = channelPaths(e.src, channel)
    local body = readNorm(readPath)
    if body == nil then return nil, ("role %s: cannot read extra file: %s"):format(roleName, readPath) end
    local size, sum = #body, fnv1a(body)
    files[#files + 1] = { src = manifestSrc, dst = e.dst, size = size, sum = sum }
    digestParts[#digestParts + 1] = roleName .. ":" .. e.dst .. ":" .. sum .. ":" .. size
  end
  ...
end
```
(The `dst` sort, `dirsOf`, and `role` table build are unchanged — `dst` names never change per channel.)

In `build()`, add a `channel` parameter and pass it through; `updater`/`basalt` read source unchanged:
```lua
local function build(channel)
  local roleTable, allDigestParts = {}, {}
  ...
  for _, name in ipairs(roleNames) do
    local role, err, digestParts = buildRole(name, ROLES[name], channel)
    ...
  end
  ... -- version digest, updater (easyhover2_suite.lua), basalt (release/basalt-full.lua): unchanged
  local manifest = { version = version, schema = SCHEMA, base = REPO,
    updater = updater, basalt = basalt, roles = roleTable }
  return HEADER .. luaValue(manifest, 0) .. "\n", nil, version, roleTable
end
```

- [ ] **Step 4: Emit / check BOTH manifests in the mode dispatch**

Replace the single `build()` call + write/check block at the bottom with a per-channel loop:
```lua
local CHANNELS = {
  { channel = "min", path = "manifest.lua" },
  { channel = "dev", path = "manifest-dev.lua" },
}

if mode == "--check" then
  local anyDrift = false
  for _, c in ipairs(CHANNELS) do
    local out, err = build(c.channel)
    if not out then print("ERROR " .. tostring(err)); writeResult("ERROR " .. tostring(err)); return end
    local existing = readNorm(c.path) or ""
    if existing ~= out then anyDrift = true; print(c.path .. " is OUT OF SYNC") end
  end
  writeResult(anyDrift and "OUT OF SYNC" or "IN SYNC")
  return
end

-- write mode
local wroteVersions = {}
for _, c in ipairs(CHANNELS) do
  local out, err, version = build(c.channel)
  if not out then print("ERROR " .. tostring(err)); writeResult("ERROR " .. tostring(err)); return end
  local f = fs.open(c.path, "w")
  if not f then print("ERROR could not open " .. c.path); writeResult("ERROR could not open " .. c.path); return end
  f.write(out); f.close()
  wroteVersions[#wroteVersions + 1] = c.path .. "=" .. version
  print(c.path .. " written: version " .. version)
end
writeResult("WROTE " .. table.concat(wroteVersions, " "))
```
(Keep `--selftest` exactly as-is above this block. The `if _G.EH2_GEN_TEST then return {...} end` pure-helper escape hatch stays untouched.)

- [ ] **Step 5: Stage `dist/` + `manifest-dev.lua` in `tools/run_gen.sh`**

Add after the `release` copy-in (line ~16):
```bash
[ -d "$ROOT/dist" ] && cp -r "$ROOT/dist" "$C0"/
[ -f "$ROOT/manifest-dev.lua" ] && cp "$ROOT/manifest-dev.lua" "$C0"/
```
Add after the `manifest.lua` copy-back (line ~36):
```bash
[ -f "$C0/manifest-dev.lua" ] && cp "$C0/manifest-dev.lua" "$ROOT/manifest-dev.lua"
```

- [ ] **Step 6: Build, regenerate, and run to verify the test passes**

Run:
```bash
node tools/build.mjs
bash tools/run_gen.sh          # writes manifest.lua + manifest-dev.lua
bash tools/run_gen.sh --check  # -> IN SYNC
bash tests/run_headless.sh     # test_manifest_channels now green
```
Expected: `run_gen --check` prints `IN SYNC`; headless prints `OK`, N passed 0 failed (N = prior + build + channels tests). Spot-check `manifest.lua` has `src = "dist/fcs/io/config.lua"` while `manifest-dev.lua` has `src = "fcs/io/config.lua"`, and both have the same `dst`.

- [ ] **Step 7: Commit**

```bash
git add tools/gen_manifest.lua tools/run_gen.sh tests/test_manifest_channels.lua tests/run_headless.sh
git commit -m "$(cat <<'EOF'
feat(manifest): emit two channels -- minified (default) + readable dev

gen_manifest threads a channel through buildRole: the min channel describes and
sums minifiable files from dist/<path>; the dev channel uses source. dst names,
role closure, and the basalt/updater entries are identical across channels; each
manifest carries its own version digest. --check validates BOTH; run_gen stages
dist/ and manifest-dev.lua in/out. Test asserts the two are parallel, basalt is
identical, and versions diverge.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Suite channel selection (`easyhover2_suite.lua`)

**Files:**
- Modify: `easyhover2_suite.lua` (const + PROTECTED + arg parse + `Suite.resolveChannel`/`Suite.manifestName` + fetch)
- Test: `tests/test_suite.lua` (channel-resolution unit tests)

**Interfaces:**
- Produces: `Suite.resolveChannel(flag, markerRaw) => "min"|"dev"` (flag wins; else trimmed marker if `"min"`/`"dev"`; else `"min"`). `Suite.manifestName(channel) => "manifest.lua"|"manifest-dev.lua"`. `Suite.CHANNEL_FILE = "/eh2_channel.txt"`. `Suite.main` writes the resolved channel to `CHANNEL_FILE` and fetches the matching manifest. `performPlan` unchanged.

- [ ] **Step 1: Write the failing tests** (append in `tests/test_suite.lua`, near the other Suite unit tests)

```lua
t.test("resolveChannel: flag wins, else marker, else default min; corrupt -> min", function()
  t.eq(Suite.resolveChannel("dev", nil), "dev", "explicit --dev")
  t.eq(Suite.resolveChannel("min", "dev"), "min", "explicit --min overrides a dev marker")
  t.eq(Suite.resolveChannel(nil, "dev"), "dev", "marker chosen when no flag")
  t.eq(Suite.resolveChannel(nil, "min"), "min", "marker chosen when no flag")
  t.eq(Suite.resolveChannel(nil, nil), "min", "absent marker defaults to min")
  t.eq(Suite.resolveChannel(nil, "garbage"), "min", "corrupt marker defaults to min")
  t.eq(Suite.resolveChannel(nil, "  dev\n"), "dev", "marker is trimmed")
end)

t.test("manifestName maps channel to the fetched file", function()
  t.eq(Suite.manifestName("min"), "manifest.lua")
  t.eq(Suite.manifestName("dev"), "manifest-dev.lua")
end)

t.test("the channel marker is a PROTECTED path (install cannot clobber the operator's choice)", function()
  t.eq(Suite.isProtected(Suite.CHANNEL_FILE), true)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `Suite.resolveChannel` is nil / attempt to call nil.

- [ ] **Step 3: Add the constant + PROTECTED entry**

Near `STATE_FILE` (line ~68):
```lua
local CHANNEL_FILE = "/eh2_channel.txt"
```
Add to the `PROTECTED` list (after the `install%.txt` entry):
```lua
  "^/eh2_channel%.txt$",
```

- [ ] **Step 4: Add the pure resolvers + expose them**

Near the other pure `Suite.*` helpers (e.g. next to `Suite.parseState`):
```lua
--- Pick the release channel. An explicit flag wins; otherwise a valid marker; otherwise min.
function Suite.resolveChannel(flag, markerRaw)
  if flag == "dev" or flag == "min" then return flag end
  markerRaw = markerRaw and markerRaw:gsub("%s+", "") or ""
  if markerRaw == "dev" or markerRaw == "min" then return markerRaw end
  return "min"
end

--- Which manifest a channel fetches.
function Suite.manifestName(channel)
  return (channel == "dev") and "manifest-dev.lua" or "manifest.lua"
end
```
Near the bottom where `Suite.STATE_FILE = STATE_FILE` is exposed, add:
```lua
Suite.CHANNEL_FILE = CHANNEL_FILE
```

- [ ] **Step 5: Parse `--dev`/`--min` and use the channel in `Suite.main`**

In the arg loop (add a `local wantChannel = nil` beside the other locals at the top of `Suite.main`, and add these branches before the `a:sub(1,2) == "--"` catch-all):
```lua
    elseif a == "--dev" then wantChannel = "dev"
    elseif a == "--min" then wantChannel = "min"
```
After `base` is resolved (after line ~1331), before the manifest fetch:
```lua
  -- ---- release channel: minified (default) or readable source (--dev)
  local channel = Suite.resolveChannel(wantChannel, readFile(CHANNEL_FILE))
  writeRaw(CHANNEL_FILE, channel .. "\n")   -- persist / normalise (writeRaw bypasses guard by design)
  local manifestFile = Suite.manifestName(channel)
  dim("channel: " .. channel .. (wantChannel and " (from flag)" or ""))
```
Change the fetch line (`:1347`) from `fetch(base .. "/manifest.lua")` to:
```lua
  local body, err = fetch(base .. "/" .. manifestFile)
```
Update the two nearby error strings that say "manifest" to use `manifestFile` where they name the file. Add to the `--help` block:
```lua
      dim("  easyhover2_suite.lua --dev        install the readable (un-minified) channel")
      dim("  easyhover2_suite.lua --min        force back to the minified channel (default)")
```

- [ ] **Step 6: Run to verify the tests pass**

Run: `bash tests/run_headless.sh`
Expected: `OK`, all passing (prior + 3 new channel tests). `run_gen --check` still `IN SYNC` (suite bytes changed → **regenerate**: `node tools/build.mjs && bash tools/run_gen.sh`, since `updater` sum moved — then re-run headless).

- [ ] **Step 7: Commit**

```bash
git add easyhover2_suite.lua tests/test_suite.lua manifest.lua manifest-dev.lua
git commit -m "$(cat <<'EOF'
feat(suite): --dev/--min channel select, persisted in /eh2_channel.txt

Default fetches manifest.lua (minified); --dev fetches manifest-dev.lua
(readable source); --min forces min. The choice persists in /eh2_channel.txt so
bare updates stay on it; an absent/corrupt marker defaults to min and is
rewritten. The marker is PROTECTED so an install/repair never clobbers it.
performPlan is unchanged -- the manifest already carries dist/ vs source src.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Dist acceptance gate (`tests/run_headless_dist.sh`)

**Files:**
- Create: `tests/run_headless_dist.sh`

**Interfaces:**
- Consumes: committed/built `dist/` (from Task 1) + both manifests (Task 2).
- Produces: a harness that copies `dist/<role dirs>` (not source) into the CraftOS computer root, keeps `tests/` as source and `require`s the modules — so the full suite exercises the **minified** code. Prints `OK` on parity.

- [ ] **Step 1: Create `tests/run_headless_dist.sh`**

Start from `tests/run_headless.sh` and change ONLY the role-dir copy-in block so the app dirs come from `dist/`, while `release/` (basalt), the suite, both manifests, and `tests/` stay as-is:
```bash
#!/usr/bin/env bash
# ACCEPTANCE GATE: run the full suite against the MINIFIED dist/ tree, proving luamin preserved
# behaviour. Mirror of run_headless.sh; only the app role dirs are sourced from dist/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== manifest sync check =="
if ! bash "$ROOT/tools/run_gen.sh" --check; then
  echo "manifest(s) OUT OF SYNC -- run: node tools/build.mjs && bash tools/run_gen.sh"
  exit 1
fi
echo ""

if [ ! -d "$ROOT/dist" ]; then echo "no dist/ -- run: node tools/build.mjs"; exit 1; fi

DATA="$(mktemp -d)"
COMP="$DATA/computer/0"
mkdir -p "$COMP"
# app role dirs: MINIFIED, from dist/
for d in fcs tools ui launchers; do [ -d "$ROOT/dist/$d" ] && cp -r "$ROOT/dist/$d" "$COMP/"; done
# not minified: basalt, the suite bootstrap, the committed manifests
[ -d "$ROOT/release" ] && cp -r "$ROOT/release" "$COMP/"
[ -f "$ROOT/easyhover2_suite.lua" ] && cp "$ROOT/easyhover2_suite.lua" "$COMP/"
[ -f "$ROOT/easyhover2_suitex.lua" ] && cp "$ROOT/easyhover2_suitex.lua" "$COMP/"
[ -f "$ROOT/manifest.lua" ] && cp "$ROOT/manifest.lua" "$COMP/"
[ -f "$ROOT/manifest-dev.lua" ] && cp "$ROOT/manifest-dev.lua" "$COMP/"
# tests stay as source and require the (now minified) modules
cp -r "$ROOT/tests" "$COMP/"
```
Then append the **identical** `startup.lua` here-doc, `timeout … CraftOS-PC … --headless`, results read, and `grep -q '^OK'` tail from `run_headless.sh` (unchanged). Make it executable: `chmod +x tests/run_headless_dist.sh`.

- [ ] **Step 2: Build dist, then run the gate**

Run:
```bash
node tools/build.mjs
bash tools/run_gen.sh
bash tests/run_headless_dist.sh
```
Expected: `OK`, same passed-count as `run_headless.sh`. If any test fails, luamin changed behaviour in the named module → stop and use `superpowers:systematic-debugging` (first suspects: a `textutils.serialise` order case or a reflection/global edge — but luamin renames locals only, so this should not happen).

- [ ] **Step 3: Commit**

```bash
git add tests/run_headless_dist.sh
git commit -m "$(cat <<'EOF'
test(gate): run the full suite against the minified dist/ tree

Acceptance gate proving luamin preserved behaviour: copies dist/ role dirs (not
source) into the CraftOS computer root, keeps tests/ as source so they require
the minified modules. Must print OK before any release.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Ship — generate committed artifacts, wire the workflow, update memory

**Files:**
- Regenerate + commit: `manifest.lua`, `manifest-dev.lua`, and the whole `dist/` tree.
- Create/modify: `docs/RELEASE.md` (the runbook).
- Modify: `C:\Users\m-kri\.claude\projects\C--Users-m-kri-Claude-Code\memory\feedback-lua-project-release-workflow.md`.

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: a green release on `main` — `dist/` + both manifests committed, both harnesses green, workflow documented, memory updated.

- [ ] **Step 1: Run the full release workflow clean**

```bash
node tools/build.mjs                 # source -> dist/ (minified)
bash tools/run_gen.sh                # regen manifest.lua + manifest-dev.lua
bash tools/run_gen.sh --check        # -> IN SYNC
bash tests/run_headless.sh           # source suite -> OK
bash tests/run_headless_dist.sh      # GATE: minified suite -> OK
```
Expected: both harnesses `OK`, `--check` `IN SYNC`.

- [ ] **Step 2: Confirm the headroom win (evidence, not estimate)**

Run: `node tools/build.mjs >/dev/null && node -e "const {execSync}=require('node:child_process'); const min=execSync('git ls-files -s dist | wc -l');" 2>/dev/null; du -sk dist/ui 2>/dev/null; du -sk ui 2>/dev/null`
Or simpler — read the `ui` role's summed `size` from each manifest and diff. Expected: `ui` role minified ≈ **437 KB** vs dev ≈ 612 KB (basalt 306 KB identical in both). Record the measured numbers in the commit body. If the `ui` role min size is not materially below dev, stop and investigate before shipping.

- [ ] **Step 3: Create `docs/RELEASE.md`**

```markdown
# EasyHover 2 — release workflow

The `ui`/`fcs` roles install over `wget run` from GitHub `raw` on `main`. A release
is: minify source -> regenerate BOTH manifests -> prove behaviour on source AND on
the minified dist -> commit source + dist/ + manifests -> push main.

    node tools/build.mjs            # source -> dist/ (minified); hard-fails on any parse error
    bash tools/run_gen.sh           # regen manifest.lua (min, default) + manifest-dev.lua (dev)
    bash tools/run_gen.sh --check   # both must be IN SYNC
    bash tests/run_headless.sh      # fast inner loop: suite vs source
    bash tests/run_headless_dist.sh # RELEASE GATE: suite vs minified dist/ -> must be OK
    git add -A && git commit -m "..."   # source + dist/ + both manifests together
    git push origin main

Channels: a bare install is minified (`manifest.lua`); `--dev` installs readable
source (`manifest-dev.lua`) for line-accurate in-game debugging; `--min` switches
back. The choice persists in `/eh2_channel.txt`. Never hand-edit `dist/` or the
manifests — they are generated. Never minify `release/basalt-full.lua`.

First-time / fresh clone: `npm install` (restores luamin 1.0.4; node_modules is
gitignored). dist/ is committed, so in-game installs never need Node.
```

- [ ] **Step 4: Update the release-workflow memory**

Edit `feedback-lua-project-release-workflow.md`: insert a build+gate step so the remembered workflow becomes `build (if the repo has tools/build.mjs) -> regen manifest(s) -> headless (source) -> headless_dist gate -> commit (source + dist/ + manifests) -> push main`, and note the two-channel model (min default, `--dev` readable) and that `dist/` is committed while `node_modules` is not. Keep the existing links.

- [ ] **Step 5: Commit the artifacts + docs and push**

```bash
git add -A
git commit -m "$(cat <<'EOF'
build(release): commit minified dist/ + both manifests; document workflow

First minified release: dist/ (luamin over fcs/ ui/ launchers/ tools/) + minified
manifest.lua (default) + readable manifest-dev.lua, all generated and committed.
ui role <SIZE_MIN> KB (was 612 KB); free space ~388 KB -> ~<FREE> KB; basalt
untouched. run_headless.sh (source) and run_headless_dist.sh (minified) both
green; both manifests IN SYNC. docs/RELEASE.md records the new workflow.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
git push origin main
```
(Fill `<SIZE_MIN>`/`<FREE>` from Step 2's measured numbers before committing.)

- [ ] **Step 6: Verify the release is live and installable**

Run: `git rev-parse HEAD` and confirm the push succeeded (`git status` clean, ahead 0). Optionally fetch the raw minified manifest to confirm GitHub serves it:
`curl -fsSL https://raw.githubusercontent.com/maar-10/EasyHover2/main/manifest.lua | head -3`
Expected: the committed minified manifest. In-game acceptance (operator-run) is the final proof: a bare `wget run … easyhover2_suite.lua` installs the `ui` role minified with comfortable headroom; `--dev` installs readable source; a `--dev`→`--min` switch keeps `/eh2_hw_config.tbl` intact.

---

## Self-Review

**Spec coverage:**
- Build tool `tools/build.mjs` (§Architecture 1) → Task 1. ✅ hard-fail gate, idempotent, config-list top-of-file, copy-through scope.
- Two-channel `gen_manifest` (§2) → Task 2. ✅ closure computed once, both manifests, `--check` both, basalt/updater identical, per-channel version.
- Suite `--dev`/`--min` + marker (§3) → Task 3. ✅ default min, persistence, corrupt→min, configs sacred (marker PROTECTED; performPlan/guard untouched).
- Dist acceptance gate (§4) → Task 4. ✅ suite vs `dist/`.
- Release workflow + memory (§5) → Task 5. ✅ documented + memory updated.
- Decisions locked (luamin Node API, per-file not bundle, commit dist, default min, never-minify list) → Global Constraints + Tasks 1–3. ✅
- Error handling (§Error handling): parse-fail non-zero+named (Task 1 Step 5); `--check` drift fails harness (Task 2/4); dist gate non-OK blocks release (Task 4 Step 2 → systematic-debugging); absent/corrupt marker → min (Task 3). ✅

**Placeholder scan:** `<SIZE_MIN>`/`<FREE>` in Task 5 Step 5 are intentional fill-from-measurement values (Step 2 produces them), not code placeholders. No "TBD"/"add error handling"/"similar to" left. ✅

**Type consistency:** `build(root)` (Task 1) is imported by `tests/build.test.mjs` (Task 1) and invoked in Tasks 2/4/5. `channelPaths`/`isMinifiable`/`buildRole(…, channel)`/`build(channel)` names consistent in Task 2. `Suite.resolveChannel`/`Suite.manifestName`/`Suite.CHANNEL_FILE` defined in Task 3 Step 4 and used in Step 5 + tested in Step 1. `MINIFY_DIRS` (JS) mirrors `MINIFY_PREFIXES` (Lua) — same four dirs, called out in Task 2 Step 3 comment. ✅

**Note on ordering:** Tasks 2, 3, 5 each move the `updater`/channel sums, so each ends by regenerating the manifests before its headless run — called out inline. Task 2 depends on Task 1's `dist/`; Task 4 depends on `dist/` existing; run tasks in order.
