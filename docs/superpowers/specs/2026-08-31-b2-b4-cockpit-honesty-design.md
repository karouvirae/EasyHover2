# EasyHover 2 -- B2 FCS SYNC labels + B4 WPT stale

**Date:** 2026-08-31
**Status:** approved (user: fix B2 and B4; B6 unassigned monitors stay dark -- not an issue)
**Sweep:** `HANDOFF-feature-complete-sweep-2026-08-30.md` B2 / B4 KEEP. B6 accepted as-is.

## Goal

BIT/CONFIG FCS SYNC shows reported SERVER/LINK (not `--`). NAV WPT/RT/DTC go read-only when the NAV PC has been silent, and do not send mutates into the void.

## B6 (out of scope)

Unassigned monitors stay blank. `buildFrames` does not create frames for `resolved.unassigned`. Note that in the sweep HANDOFF as accepted, not a defect.

## B2 -- FCS SYNC labels stay `--`

**What:** `fcssync.build` seeds `SERVER: --` / `LINK: --`. `apply()` already paints RUNNING/STOPPED and FCS ACTIVE/WAITING from `cfgserver:status()`, but nothing calls it: BIT/CONFIG is event-mode (`applyNow` does not `handle.apply` event tops). START/STOP do start/stop the server and bump `uiRev`; chrome never follows.

**Fix (local to `ui/basalt/bitconfig/fcssync.lua`):**

1. After `apply` is defined, call it once before `return` (same idea as other BIT pages' `region:apply(nil)`).
2. START/STOP `onClick`: `M._onButton(...)` then `apply()`.

No renderpolicy change. Sitting on the page after START shows WAITING until the next apply (a later START/STOP or re-entry). That is enough to kill `--`. Live FCS ACTIVE while parked is not this ticket.

## B4 -- WPT/RT/DTC look live with NAV down

**What:** `wptClient:stale()` exists, zero callers. `online` is only set `true` in `onReply`. After one good reply the menu looks live forever. Mutates/disk ops fire-and-forget. Event-mode NAV already applies on `onWptReply` (store arrived); silence never applies.

**Fix:**

1. `C:refreshOnline(now, maxAge)` -- if `stale(now, maxAge)` then `online = false`. Returns `online`. `now` defaults to `self.now()`.
2. `mutate` / `diskOp`: `refreshOnline()` then send only if `online`. `request()` still sends (recovery poll) but calls `refreshOnline` first.
3. NAV screen `refresh()`: `refreshOnline()` then disable mutate/disk action-row buttons when offline. Tabs WPT/RT/DTC stay clickable (read-only last cache). DTC result label already uses `online`.
4. UI 2 s poll: after `refreshOnline`, if `online` fell true->false, `M.applyEventTop(..., "nav")` so the parked NAV page paints "NAV offline" / disabled actions without a click. Extract `M.tickWptFreshness(runtime, frameRecs, now)` for tests.

Do not invent a local store. Last cache may still display; it must not look writable.

## Tests

- `tests/test_bitconfig_fcssync.lua`: after `build` (no caller `apply`), labels are `SERVER: STOPPED` / `LINK: STOPPED` not `--`. START click (via the wired onClick) then `status.running=true` path leaves `SERVER: RUNNING`.
- `tests/test_wptclient.lua`: `stale` with no `lastReplyAt` / inside window / past 6000 ms. `refreshOnline` clears `online`. `mutate`/`diskOp` do not send when stale; `request` still sends.
- `tests/test_basalt_app.lua`: `tickWptFreshness` applies nav only on a true->false drop.
- `tests/test_page_nav.lua`: wptedit HERE row disabled when client stale.

## Out of scope

B6 frames for unassigned monitors. A/P apply (B3). Making `fcssync` or `nav` rate-mode. Changing `stale` default 6000 ms.
