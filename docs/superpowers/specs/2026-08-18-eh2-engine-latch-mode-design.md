# EH2 — Engine fuel-feed "latch mode" (persistent fail-safe block)

**Date:** 2026-08-18
**Status:** Design approved, ready for planning
**Area:** `ui/engine.lua`, `ui/relaywriter.lua`, `ui/config.lua`, UI config page

## Problem

The fuel funnel above the portable engine passes solid fuel **only while its redstone
input is UNPOWERED**. The UI PC blocks feeding by *holding the relay HIGH*, and dips it
LOW for `pulseMs` to let exactly one item through. This is fail-safe **in intent** —
`master OFF` / boot / error all hold HIGH = blocked — but that safety **only exists
while the software is actively running to assert it.**

The funnel's true rest state is the dangerous one:

- **Funnel unpowered = flows. Powered = blocked.** "Blocked" is an *active* state the PC
  must continuously drive.
- On chunk-load reboot the redstone relay comes up LOW (it does **not** latch its last
  state) and nothing drives it HIGH until the app fully boots.
- The relay HIGH is not asserted at `Engine.new` — it first fires on the **first
  `tick()`** of the control loop (`ui/basalt/app.lua:369` constructs the engine with no
  write; HIGH only lands after Basalt + the whole UI init, then the loop's first tick).
  Adding UI logging pushed more work in front of that first tick, widening the gap.

**Symptom:** returning from far away → chunk reload → UI PC reboots → the funnel is
unpowered (flowing) for the multi-second window until the software takes over →
a full stack of fuel is dumped into the engine. A crashed or wedged PC does the same.

Root cause in one sentence: **"blocked" requires the PC to be alive and asserting;
pure redstone cannot tell "PC dead" from "PC alive and choosing to feed," because both
are 0 V.** A real fix must make *blocked* a state that survives with no PC involvement.

## Approach: a Create Powered Latch remembers "blocked" for us

Insert a **Create Powered Latch** between the relay and the funnel. The latch's output
drives the funnel; the PC *pulses* the latch between states instead of *holding* a level.
The latch — a world block — remembers its state with **zero** PC involvement, including
across PC death and chunk reload. This adds the memory the redstone relay lacks, and
**does not touch the funnel wiring** (the funnel still sees "powered = blocked").

### Verified latch semantics (Create source, mc1.21.1)

From `PoweredLatchBlock` / `ToggleLatchBlock`
(`com/simibubi/create/content/redstone/diodes/`):

- Output signal = `POWERING ? 15 : 0`, emitted out the **FRONT** (facing) face.
- `POWERING` is changed **only on input edges** in `tick()`; with both inputs idle it
  **holds** its value. This is a true SR memory latch.
- `POWERING` is a **blockstate property** → saved with the world → **persists across
  chunk unload/reload.**
- **BACK** face = SET: a rising edge sets `POWERING=true` (output ON).
- **SIDE** faces (left/right of facing) = RESET: a rising edge sets `POWERING=false`
  (output OFF).
- `getDelay = 1` tick; edge handling is scheduled-tick based, so an input must be held
  present long enough (≥ ~1–2 redstone ticks) for the scheduled tick to read it.

### Physical mapping (funnel powered = blocked)

We want **output ON = blocked**. Output ON = `POWERING=true` = set via **BACK**.

| Action        | Latch effect        | Funnel   | Drive                          |
|---------------|---------------------|----------|--------------------------------|
| **Block**     | `POWERING=true` ON  | blocked  | pulse **BACK** line, release   |
| **Feed/open** | `POWERING=false` OFF | flowing  | pulse a **SIDE** line, release |

- Latch **FRONT** → funnel input.
- Relay line A → latch **BACK** (block/set).
- Relay line B → latch **SIDE** (feed/reset).

Between pulses **both lines are idle** and the latch holds — that is the memory that
makes the whole scheme fail-safe.

## Behaviour

Mode is selected by config; the two modes share the same state machine and the same
`pulseMs` / `intervalMs` timings.

### `basic` mode (today, unchanged, default)

Level-hold on a single relay side: HIGH = blocked, dip LOW for `pulseMs` to feed one
item. Exactly the current behaviour. This stays the default so the current craft keeps
working untouched until the latch is physically built.

### `latch` mode (new)

**Every feed event is identical** — the kickstart when the engine is switched on, the
prime button, and each periodic interval feed all do the same thing:

1. **Pulse the FEED (SIDE) line** → latch OFF → funnel opens → one item passes.
2. Wait **`pulseMs`** (the open window; reused unchanged — same meaning as today's
   "dip LOW for `pulseMs`").
3. **Pulse the BLOCK (BACK) line** → latch ON → funnel re-blocked. Held with no further
   PC involvement.

- Periodic feeds recur every **`intervalMs`** (unchanged).
- At rest / `master OFF` / boot / error / after any feed: the latch simply **holds ON**.
  The PC does **not** re-assert every tick — this is the core win.
- **No new user settings.** `pulseMs` = FEED→BLOCK gap; `intervalMs` = feed cadence.

## Design detail

### State machine (`ui/engine.lua`) — unchanged timeline

The existing pulse timeline — "open now, close after `pulseMs`, next feed in
`intervalMs`" — is **identical** in both modes. `pulseEndsAt` / `nextPulseAt` /
`kickstart` / `masterDefault` / `feedNow` / `blockNow` all keep their current roles.
Only the physical **write edge** differs:

- `basic`: `_write(feeding)` holds a level (write-on-change on the single signal).
- `latch`: `_write(feeding)` fires a **momentary pulse** on the FEED line (feeding=true)
  or the BLOCK line (feeding=false), **only on the logical transition**. The existing
  write-on-change guard (`lastWritten == signal → return`) naturally suppresses the
  repeated `_write(false)` re-asserts (e.g. the `tick()` "held blocked" re-assert and
  `master OFF`), so latch mode does not spam BACK pulses every tick.

### Pulse mechanics (latch mode)

A "pulse" = raise the line, then lower it after a short fixed width so `POWERING` is left
holding with the line idle (never rely on holding a line — that would forfeit the memory
across PC death).

- Introduce an **internal constant** `LATCH_LINE_MS` (≈150 ms, ≥ ~2 redstone ticks for
  reliability on a busy shared server). **Not** a user setting.
- The tick loop lowers any raised line whose down-time has passed (a small `lineDownAt`
  per line — new state that exists only in latch mode).
- **Ordering constraint:** the FEED pulse must be fully lowered before the BLOCK pulse
  rises, i.e. `LATCH_LINE_MS < pulseMs`. Enforce a floor on `pulseMs` in latch mode
  (e.g. `pulseMs ≥ 2 × LATCH_LINE_MS`); clamp or validate at config load / in the UI.
- Because the two inputs are pulsed one-at-a-time with the other already idle, the latch
  always sees clean single-edge transitions (no both-high ambiguity).

Exact interface for driving two lines (single `writer(line, bool)` vs. two level-writers
`backWriter`/`sideWriter`) is an implementation choice for the plan; it must preserve the
injected-writer testability that `ui/engine.lua` already has.

### Relay writer (`ui/relaywriter.lua`)

- `basic`: unchanged single-side passthrough (keeps the "release the abandoned side on
  side change" behaviour).
- `latch`: drive **two** sides as independent lines and emit the timed pulses the engine
  schedules. Same "release on rebind/side-change" hygiene applies to both lines.

### Config (`ui/config.lua`)

Extend the `engine` and `relay` blocks; all additions are additive and default to
today's behaviour via the existing deep-merge:

```lua
engine = { mode = "basic", pulseMs = 250, intervalMs = 330000,
           invert = false, kickstart = true, masterDefault = false },
relay  = { name = nil, side = nil,        -- side: basic mode (unchanged)
           blockSide = nil, feedSide = nil }, -- latch mode: BACK / SIDE lines
```

- `mode = "basic" | "latch"`, default `"basic"`.
- `basic` uses `relay.side`; `latch` uses `relay.blockSide` (→ latch BACK) and
  `relay.feedSide` (→ latch SIDE). Final field names may be refined in the plan.
- `invert` applies to `basic` mode only (it flips the single physical signal). In
  `latch` mode block/feed are distinct lines, so `invert` is ignored; the plan should
  assert this rather than silently carry it.

### UI config page (in scope, minimal)

The config UI must let the pilot pick the mode and, in latch mode, assign the two relay
sides (BACK/block and SIDE/feed) the way it currently assigns the single side. Keep it as
close to the existing side-picker flow as possible; surface `blockSide`/`feedSide` only
when `mode = latch`.

## Fail-safety

| Failure                         | `basic` (today) | `latch` (new)                    |
|---------------------------------|-----------------|----------------------------------|
| Chunk-load reboot (return)      | leaks a stack   | ✅ latch holds ON through reboot |
| Crash / wedge **while blocked** | leaks           | ✅ latch holds ON                |
| Chunk reload while blocked      | leaks           | ✅ `POWERING` persists in world  |
| Crash **during** the feed window| leaks           | ⚠️ leaks until reboot (accepted) |

**Residual (accepted for v1):** if the PC dies during the `pulseMs` feed window (latch
momentarily OFF, mid-item), the latch stays OFF and the funnel leaks until a reboot
re-asserts BACK. That window is a few hundred ms out of every `intervalMs` (default
330 000 ms) — negligible, and vastly better than "leaks the entire time the PC is down."

**Optional v2 hardening (out of scope):** a Create Pulse Extender/Repeater on the FEED
line that auto-fires the BACK/block input after a fixed delay, so hardware re-blocks even
on a mid-feed crash. Closes the residual window at the cost of more contraption redstone.

A chunkloader remains a nice-to-have (keeps the craft running so no reboot happens at
all) but is **no longer load-bearing** for fuel safety.

## Testing

Follows the project's CraftOS-PC headless convention with a **mocked relay** (real mod
peripherals don't exist in CraftOS-PC):

- Inject a capturing writer that records the full `(line, bool, t)` sequence.
- Assert, for kickstart / prime / periodic feed, the sequence is: FEED-line rise →
  FEED-line fall (≤ `LATCH_LINE_MS`) → `pulseMs` gap → BLOCK-line rise → BLOCK-line fall.
- Assert the FEED pulse is fully lowered before the BLOCK pulse rises
  (`LATCH_LINE_MS < pulseMs`).
- Assert `master OFF` / repeated `tick()` while blocked emit **no** repeated BACK pulses
  (write-on-change suppression).
- Assert `basic` mode is byte-for-byte behaviour-identical to today (single-side level,
  dip LOW for `pulseMs`).
- Assert `pulseMs` floor enforcement in latch mode.
- Whole suite green (`bash tests/run_headless.sh`) plus dist + e2e as usual.

## Out of scope

- Powered Latch v2 hardware auto-close (pulse extender).
- Chunkloader build.
- Any FCS-side change (fuel feed is UI-PC-owned).
