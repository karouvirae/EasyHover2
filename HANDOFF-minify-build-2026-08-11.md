# HANDOFF — EasyHover 2 pre-deploy minify build step

**Created:** 2026-08-11 (Claude Code desktop) — **for pickup in the Claude CLI terminal.**
**Repo:** `EasyHover2` (git, `main`, origin `github.com/maar-10/EasyHover2`).
**Full design spec:** [`docs/superpowers/specs/2026-08-11-minify-build-step-design.md`](docs/superpowers/specs/2026-08-11-minify-build-step-design.md)

Brainstorming (Superpowers) is complete and the design is **approved**. Nothing has
been implemented yet. **Status: not started, recorded-state only** (a second concurrent
session was mid-flight — see the banner). Next Superpowers step is **`writing-plans`**
against the spec, then **`executing-plans`** (or `subagent-driven-development`).

---

## ⚠️ CONCURRENCY — READ BEFORE ANYTHING

This handoff overlaps a **second, concurrent session** on the same repo. That session
landed **`d7be6de` (2026-08-11): "install files in place, one at a time."** It changed
`Suite.performPlan` to delete-then-write each verified file directly
(`easyhover2_suite.lua:594`) — so the install peak is now **one file of headroom, not
2×**. **That was the actual fix for the disk-full crash.**

Consequences for THIS task:
- The original "2× update-time staging peak" diagnosis is **obsolete** — do not repeat it.
- Minify is now a **headroom improvement, not a crash fix** (see corrected Why below).
- **Before implementing, reconcile with the other session's handoff** (its state was
  being recorded separately by the user) so the two efforts don't clash on
  `easyhover2_suite.lua` / `gen_manifest` / the manifest format.

## Why (corrected)

The `ui` role occupies **612 KB — 61 % of the default 1 MB disk** (basalt 306 KB, the
irreducible pinned floor; + ~306 KB UI app code). With the in-place install (`d7be6de`)
it **no longer overflows** — but headroom for configs, the rolling backup, DTC disk
exports, the suite, and logs is thin. Minifying the app half (luamin, ~57 %) drops the
`ui` role to **~437 KB**, restoring free space from ~388 KB to **~563 KB**. Basalt is
untouched.

## Decisions locked (do not re-litigate)

1. **luamin** via its **Node API** (`require('luamin').minify(src)`), not the CLI.
2. **Per-file minify** into a committed **`dist/`** tree mirroring source — not a bundle.
3. **Two channels:** `manifest.lua` = **minified (default)**; `manifest-dev.lua` =
   readable source, selected by suite `--dev`. Marker file `/eh2_channel.txt`.
4. **Commit `dist/`** to the repo (GitHub raw serves it; keeps `wget run` model).
5. **Default install = minified.**
6. **Never minify:** `release/basalt-full.lua` (vendored, pinned), `manifest*.lua`
   (data), `easyhover2_suite.lua` / `easyhover2_suitex.lua` (bootstrap/trust root).
7. **Minify scope:** `fcs/ ui/ launchers/ tools/` `.lua` only.

## Proven facts (measured this session)

- Node **v22.20.0**, npm 10.9.3, **luamin 1.0.4** all present.
- luamin's **API** works (CLI arg-parsing is buggy — use the API).
- **All 89 app files parse**; **57.1 % size reduction** (340 KB → 146 KB, ~190 KB saved).
- Exact `ui` role (from manifest) = **612 KB** (basalt 306 KB + ~306 KB app). Minify the
  app half → `ui` role **~437 KB**; free space ~388 KB → ~563 KB. `fcs` role = 106 KB.
- Test harness `tests/run_headless.sh` copies role dirs (`fcs tools ui release
  launchers`) into the CraftOS computer root and `require`s modules — so the dist
  acceptance gate is just the same harness pointed at `dist/`.

## Work to build (turn into a plan)

1. **`tools/build.mjs`** — walk the 4 app dirs, `luamin.minify` each `.lua` → `dist/<path>`;
   hard-fail (nonzero, name file) on any parse error; write nothing partial;
   deterministic/idempotent; minify-dirs + copy-through lists as top-of-file config.
   luamin must be resolvable — add a `package.json` + `node_modules` (or a pinned
   local install) so `require('luamin')` works in-repo; decide during planning whether
   to commit `node_modules` or document `npm install`.
2. **Extend `tools/gen_manifest.lua`** — compute the role closure once (unchanged),
   then emit **both** `manifest.lua` (src→`dist/…`, sums over minified bytes) and
   `manifest-dev.lua` (src→source, sums over source bytes). `dst` names + basalt entry
   identical across channels; each keeps its own `version`. `--check` must validate
   **both**.
3. **`easyhover2_suite.lua`** — `--dev` fetches `manifest-dev.lua`, `--min` forces
   minified; persist choice in `/eh2_channel.txt`; default = min; channel switch = a
   repair (same `dst` names). Keep config-sacred guarantees intact.
4. **`tests/run_headless_dist.sh`** — clone of `run_headless.sh` that copies `dist/`
   role dirs (not source) into the computer root; full suite must print `OK`. This is
   the release acceptance gate.
5. **Docs/workflow** — update the release runbook (see below).

## Release workflow (new — supersedes plain "regen manifest → commit → push")

```bash
node tools/build.mjs             # source -> dist/ (minified); hard-fail on parse error
bash tools/run_gen.sh            # regen BOTH manifests
bash tests/run_headless.sh       # fast inner loop: suite vs source
bash tests/run_headless_dist.sh  # GATE: suite vs minified dist/  -> must be OK
git add -A && git commit -m "…"  # source + dist/ + both manifests
git push origin main
```

## Acceptance criteria

- `node tools/build.mjs` produces `dist/` mirroring the 4 app dirs, minified, and
  fails loudly if any file stops parsing.
- Both manifests regenerate and `run_gen.sh --check` passes for both.
- `tests/run_headless_dist.sh` prints `OK` (behaviour parity on minified code).
- Fresh `wget run` install (default) lands the **minified** channel (`ui` role ~437 KB,
  ~563 KB free); `--dev` lands readable source; switching channels keeps
  `/eh2_hw_config.tbl` and other protected configs untouched.
- In-game: `ui` role installs/updates with comfortable disk headroom.

## Gotchas / guardrails (from memory + this repo)

- **`textutils.serialise` key-order parity** (`reference-cct-serialise-order`): luamin
  preserves table-constructor order, so parity should hold — the dist gate is what
  proves it. If a `*_manifest`/serialise test diverges, that's the first suspect.
- **Basalt full build only** (`feedback-basalt-full-build`) — never swap or re-minify it.
- **No optimistic UI** (`feedback-no-optimistic-ui`) — unrelated but don't regress it.
- **End the finishing post with the suite install `wget run` command**
  (`feedback-suite-install-in-wrapups`).
- Use **`superpowers:test-driven-development`** for `build.mjs` and the gen_manifest
  change; **`systematic-debugging`** if the dist gate ever goes red.
- CraftOS headless self-test pattern + standing perms: see the `dev-permissions` skill.

## How to resume in the CLI

1. `cd` into `EasyHover2`.
2. Read the spec: `docs/superpowers/specs/2026-08-11-minify-build-step-design.md`.
3. Invoke **`superpowers:writing-plans`** against the spec to produce the implementation
   plan, then execute it (`executing-plans` / `subagent-driven-development`) behind the
   acceptance gate above.
