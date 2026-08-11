# HANDOFF — EasyHover 2 pre-deploy minify build step

**Created:** 2026-08-11 (Claude Code desktop) — **for pickup in the Claude CLI terminal.**
**Repo:** `EasyHover2` (git, `main`, origin `github.com/maar-10/EasyHover2`).
**Full design spec:** [`docs/superpowers/specs/2026-08-11-minify-build-step-design.md`](docs/superpowers/specs/2026-08-11-minify-build-step-design.md)

Brainstorming (Superpowers) is complete and the design is **approved**. Nothing has
been implemented yet — that's your job. Next Superpowers step is **`writing-plans`**
against the spec, then **`executing-plans`** (or `subagent-driven-development`).

---

## Why (one paragraph)

The `ui` role blows CC:Tweaked's 1 MB disk quota **at update time**, not at rest.
`easyhover2_suite.lua` stages every changed file to a `.eh2new` copy while the old
file still exists and commits all-at-once (`easyhover2_suite.lua:543`–587), so an
update needs ~2× the role size, and a basalt-touching update double-counts the 306 KB
basalt. Fix = minify the app source with **luamin** so both steady state and the 2×
peak drop under 1 MB.

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
- `ui` steady state ~0.5 MB → ~0.38 MB; worst update peak ~1.05 MB → ~0.8 MB.
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
- Fresh `wget run` install (default) lands the **minified** channel and fits with
  update-peak headroom under 1 MB; `--dev` lands readable source; switching channels
  keeps `/eh2_hw_config.tbl` and other protected configs untouched.
- In-game: `ui` role installs and updates without hitting the quota.

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
