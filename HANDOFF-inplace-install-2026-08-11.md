# HANDOFF — EasyHover 2 in-place install engine

**Created:** 2026-08-11 (Claude Code desktop) — **for pickup in the Claude CLI terminal.**
**Repo:** `EasyHover2` (git, `main`, origin `github.com/maar-10/EasyHover2`).
**Commit:** **`d7be6de`** — *"feat(suite): install files in place, one at a time, instead of full `.eh2new` staging"* — **DONE, pushed, green.**

This is the **counterpart handoff** the minify handoff
([`HANDOFF-minify-build-2026-08-11.md`](HANDOFF-minify-build-2026-08-11.md), §CONCURRENCY)
told you to reconcile against. It records **exactly what `d7be6de` changed in the shared
files** so the minify work can build on top without clashing.

**Status of THIS task: complete.** The code change is implemented, tested (593 headless +
11-phase e2e + manifest IN SYNC), committed, and pushed. Nothing here is half-written. The
only EH2 work left is **in-game verification** (backlog at the bottom) — none of it blocks
the minify task.

---

## What `d7be6de` actually changed

**Goal:** kill the "disk full" crash by never holding a 2nd full copy of the role on disk.
The old `Suite.performPlan` downloaded **every** file into a `.eh2new` staging copy first,
verified them all, then moved them into place (all-or-nothing) → peak = **2× the role**. Now
each file is checksum-verified **before** it is written, then **replaces its target directly**,
one at a time → peak = **one file of headroom**.

Trade: the *set* is no longer atomic. A mid-run drop leaves earlier files new, the rest old.
That is **self-healing** — the install record (`/easyhover2_install.txt`) is stamped **only
after every file lands**, so a half-finished run still scores as `update`/`repair` and the
next run (which re-checks every file) re-fetches whatever still differs.

### Files touched (all in `d7be6de`)

| File | Change |
|---|---|
| `easyhover2_suite.lua` | `Suite.performPlan` fetch→verify→**delete-then-write in place** loop (**~L563–597**). Fetches via **`Suite.fetch`** (`local doFetch = Suite.fetch or fetch`, **L563**) so failure semantics are injectable/testable. Truthful mid-run failure message (`interrupted()` — says *N of M already replaced*, not "nothing was changed"). `#staged` → `written` counter. Header "FIVE PROPERTIES" block: property #2 rewritten from **"ALL OR NOTHING"** to the in-place model (**~L29–39**). |
| `manifest.lua` | Regenerated — only the `updater` stamp changed (suite bytes changed). `size=68261`, resynced. |
| `tests/test_suite.lua` | New test *"performPlan writes each verified file in place; a mid-run failure keeps the earlier ones"* — injects `Suite.fetch`, asserts already-fetched files sit at their **FINAL** paths with **no `.eh2new`** left. (RED against the old staging code, verified by stash.) |

### Deliberately kept
- The **`.eh2new` STAGE constant** still exists — `Suite.selfUpdateNotice` uses it for its own
  **single-file** atomic self-replace (**~L1552**), which is *not* the payload disk problem and
  is worth keeping atomic. `pruneRole` also still skips `.eh2new`. Do **not** assume `.eh2new`
  is fully gone.
- `SuiteX` was **not touched** — it has **no installer of its own** and delegates to
  `Suite.performPlan` (`easyhover2_suitex.lua:514`), so it inherited the in-place behavior for
  free. "Both suites" from the original ask = one engine change.

---

## ⚠️ COLLISION MAP with the minify task

Both efforts edit the same three things. Here is how they interleave — **minify can proceed on
top of `d7be6de` with no rebase; just be aware of these regions:**

1. **`easyhover2_suite.lua`** — *different regions, low textual conflict risk.*
   - My change: `Suite.performPlan` write loop (**L563–597**) + header property #2.
   - Minify's change (planned): `Suite.main` arg-parsing for `--dev`/`--min`, `/eh2_channel.txt`
     persistence, and **which manifest** to fetch (`manifest.lua` vs `manifest-dev.lua`) — that
     lives up in `Suite.main` (~L1270+) and the manifest-fetch (~L1322), **not** in the write
     loop. They should not overlap line-for-line.
   - **Shared surface to coordinate:** the header doc block (both may want to add a note), and
     the fact that channel-switch is "a repair" — a repair now runs the **in-place** loop, so
     the channel switch already benefits from the low footprint. Keep the config-sacred +
     `guard()` guarantees intact; my loop still routes every write through `writeRelease`→`guard`.

2. **`Suite.fetch` is now the per-file fetch seam.** Minify changes *which manifest* is fetched,
   not the per-file fetch — compatible. If minify ever wants to inject/observe per-file fetches
   too, `Suite.fetch` is the single point (already exposed at bottom of the suite).

3. **`gen_manifest.lua` / manifest format.** I only **regenerated** `manifest.lua` (updater
   stamp). Minify **extends** `gen_manifest` to emit **both** `manifest.lua` (minified, sums over
   `dist/` bytes) + `manifest-dev.lua` (source). When minify regenerates, it **subsumes** my
   `manifest.lua` — no conflict, but the `updater` stamp must be recomputed over whatever suite
   bytes ship (the suite is on minify's **"never minify"** list, so its bytes are the same source
   bytes in both channels — the stamp is identical across channels). ✅ consistent.

4. **Tests.** My new `test_suite.lua` case is source-only and channel-agnostic — it will pass
   unchanged under `run_headless_dist.sh` too (it never reads a manifest; it drives
   `performPlan` with a hand-built spec + injected fetch).

**Net:** minify's original "2× staging peak" diagnosis is already **obsolete** (its own §14
says so). Minify is now a **headroom** improvement, and it composes cleanly with `d7be6de`.

---

## Verification already run (for THIS task)

```bash
bash tools/run_gen.sh && bash tools/run_gen.sh --check   # -> IN SYNC
bash tests/run_headless.sh                               # -> 593 passed, 0 failed
bash tests/run_suite_e2e.sh                              # -> 11 phases PASS (real fetch, localhost mirror)
```
Also confirmed `manifest.updater.size == wc -c easyhover2_suite.lua == 68261` so
`selfUpdateNotice` will not false-alarm "Suite out of date".

## EH2 in-game backlog (NOT blocking minify; user runs these)

- **In-place install** — verify a real `wget run` update of the `ui` role no longer disk-fulls
  and that a deliberately-interrupted run self-heals on re-run.
- **Task 28** — full cockpit in-game smoke (multi-monitor, pages, drill-downs, FCS boot phase).
- **Merged "flight" page** — overhead 1×2 monitors render/behave.
- **Dropdown swap** — MDB/UI CAL/EMC-config/monitor-assign dropdowns usable in-game; watch for a
  dropdown overflowing a narrow frame's bottom.

## How to resume in the CLI

1. `cd` into `EasyHover2`; `git pull` (HEAD should be at/after `d7be6de`).
2. **This task needs no code work** — it's done. If continuing the **minify** task, read
   [`HANDOFF-minify-build-2026-08-11.md`](HANDOFF-minify-build-2026-08-11.md) and treat the
   Collision Map above as the "reconciled with the other session" step it asked for.
3. Suite install (house rule): `wget run https://raw.githubusercontent.com/maar-10/EasyHover2/main/easyhover2_suite.lua`
