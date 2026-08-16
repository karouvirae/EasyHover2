# EH2 Remote Beacon Update + SuiteX "Beacon updater" tool — design

A remotely-triggerable "update + reboot" capability for the **beacon** role, plus the workspace's
first optional **advanced tool** in SuiteX (the beacon updater). Lets an operator patch all live
beacons from any PC's shell — over the ender-modem channel the beacons already broadcast on
(default 65000) — without visiting each beacon. Bundled with a horizontal-honest fix to the beacon's
own self-check, which is the first real payload to deploy. Brainstorm: this session, 2026-08-16.

## Motivation

The 2026-08-16 NAV GPS hotfix (grade quality on HDOP, not 3D PDOP — commit `0fe6ad4`) lives entirely
on the NAV PC, so it needs no beacon change. But the beacons run their **own** local self-check
(`beacon.runtime.constellation` → `geometry.grade`), which still flags a wide, flat (near-build-
height) constellation as `UNUSABLE — coplanar` — the same dishonesty the NAV fix corrected. Fixing
that requires deploying to all 4 beacons, which today means physically visiting each one. This design
adds remote patching so future beacon changes are one shell command, and ships the self-check fix as
its first payload.

## Scope

**In:**
- Remote update protocol (command + ack frames) on the shared GPS channel.
- Beacon-side: token-guarded update handler + reboot; `updateToken` config; a console action to set it.
- The `beaconupdate` shell tool (broadcast command, collect acks, report).
- Manifest `tools` section (min + dev variants) + SuiteX Advanced-tab "Beacon updater" checkbox.
- Beacon self-check made horizontal-honest (HDOP-based verdict), consistent with the NAV.

**Out (YAGNI / later):**
- Live uninstall of the tool via the checkbox (ticking installs; removal is manual/out of scope).
- Over-the-modem code push (rejected — ender message size limits).
- Remote update of any role other than beacon (the tool targets beacons only).

## Approaches considered (update mechanism)

- **A — Reuse the classic Suite (CHOSEN).** On a valid command the beacon runs
  `easyhover2_suite.lua` for its own recorded role, then `os.reboot()`. Config is sacred
  (coordinates + token preserved by the Suite's protected-path guard), the min/dev channel persists,
  and checksum verification is free. No new install/verify logic to maintain.
- **B — Custom lightweight re-fetch.** Rejected: reimplements config-preservation + checksum logic
  the Suite already does correctly.
- **C — Push file bytes over the modem.** Rejected: ender-modem message-size limits make shipping
  whole files (incl. closures) fragile.

## Protocol (shared channel, default 65000)

Two new frame kinds, distinct from the GPS broadcast frame (`{id,x,y,z,seq}`):

- **Command** (updater → beacons): `{ k = "eh2_beacon_update", token = <secret> }`
- **Ack** (beacon → updater): `{ k = "eh2_beacon_update_ack", id = <beaconId> }`

Frames are serialized with the **same wire format** the GPS codec uses — `fcs.comms.protocol`
encode/decode (which is what `nav/comms/gpsproto` wraps). Coexistence on the one channel is already
guaranteed: `gpsproto.decode` returns nil for any frame lacking numeric x/y/z (verified — see
`nav/comms/gpsproto.lua:15-20`), so the mesh receiver silently ignores update/ack frames; and the
update codec validates the `k` field, so it returns nil for GPS frames.

**Fail-closed rules (both confirmed):**
- A beacon acts on a command ONLY if `token` matches its configured `updateToken` AND that token is
  non-trivial (non-empty after trimming whitespace). A beacon with no/blank token ignores all
  commands (no "empty matches empty" bypass) and never reboots.
- The updater tool REFUSES to broadcast if it has no non-trivial token configured (prompts to set
  one first).

## Components

### 1. `beacon/update.lua` (NEW — pure, testable)
The token/frame logic, no peripherals:
- `M.CMD_KIND = "eh2_beacon_update"`, `M.ACK_KIND = "eh2_beacon_update_ack"`.
- `M.validToken(t) -> bool` — true iff `t` is a string that is non-empty after `:gsub("%s","")`.
- `M.command(token) -> frame` / `M.ack(id) -> frame` — build frames.
- `M.encode(frame) -> string` / `M.decode(string) -> frame|nil` — reuses `fcs.comms.protocol`
  encode/decode (same wire format as `gpsproto`); decode returns nil for anything whose `k` isn't
  one of the two kinds.
- `M.accepts(frame, cfgToken) -> bool` — true iff `frame` is a well-formed command whose `token`
  is valid AND equals `cfgToken` (which must itself be valid). This is the single fail-closed gate.

### 2. `beacon/config.lua` (MODIFY)
- Add `updateToken` (string, default `nil`) to the schema + `withDefaults`. Never overwritten by a
  Suite reinstall (config is sacred; it lives in `/eh2_beacon.tbl`).

### 3. `beacon/app.lua` (MODIFY — thin glue only)
- In the existing `modem_message` branch: after feeding the mesh receiver, `beacon.update.decode`
  the raw message; if `beacon.update.accepts(frame, cfg.updateToken)`:
  1. send the ack frame on `cfg.channel` (so the operator's tool sees it before we go down);
  2. `shell.run("wget", "run", <suiteURL>)` — the Suite detects role=beacon from its state file and
     reinstalls in place (config preserved, channel persisted);
  3. on success, `os.reboot()`. On failure (no http / fetch error), do NOT reboot — print a brief
     error line and keep running the old code.
- `<suiteURL>` = `<REPO>/easyhover2_suite.lua`, where `REPO` is the same default repo constant the
  other roles use (a small, documented duplication, like `ui/basalt/app.lua`'s `REPO`).
- New console action `[U] set update token` (see below).

### 4. `beacon/console.lua` (MODIFY)
- Add `[U] set update token` to `ACTIONS`/footer. `Console.readToken(reader)` reads a line, trims,
  and returns it (or nil to cancel/keep). App saves it to config. The token is shown as set/unset
  (never echoed in full) on the screen.
- The `constellation` line changes per component 6.

### 5. `beacon/runtime.lua` (MODIFY) + `tools/beaconupdate.lua` (NEW) + `launchers/beaconupdate.lua` (NEW)
- **Runtime:** `R:selfQuality(now)` — compute `geometry.hdop` + `geometry.dopQuality` at THIS
  beacon's own configured position over `[self + heard peers]`, returning `{ quality, errorEst,
  hosts }` (or hosts-only when < 4). Feeds the console (component 6). `R:constellation` stays for
  any caller that wants the raw grade, but the console no longer renders `USABLE/UNUSABLE`.
- **`tools/beaconupdate.lua` (pure/testable):** `M.run(deps)` where deps inject modem, token,
  channel, now, and a sleep/timeout — so the broadcast + ack-collection loop is unit-tested with a
  mock modem. Behavior: refuse if token invalid; broadcast `beacon.update.command(token)`; collect
  ack ids for `timeoutS` (~2.5s); return the sorted list of responders. Config read/write of
  `/eh2_beacon_update.tbl` (token + channel, channel default 65000) is a thin injected seam.
- **`launchers/beaconupdate.lua`:** the shell entry — wraps the real wireless modem, loads/writes
  the config (prompts for the token on first run, saving it), calls `tools.beaconupdate.run`, and
  prints `updating: beacon-67, beacon-68, ...` (or "no beacons answered" / the error).

### 6. Beacon self-check display (horizontal-honest)
`beacon/console.lua`'s constellation row becomes, mirroring the NAV wording:
`constellation  <n> of 4   GOOD|FAIR|POOR  ~<e> blk` (thresholds identical to `nav/ui/main.lua`:
GOOD ≥ 0.75, FAIR ≥ 0.4, else POOR; `~<e> blk` from `errorEst` when present). Under 4 hosts →
`<n> of 4  waiting` (dim). `geometry.grade`/coplanarity is no longer a disqualifier here (it never
was for horizontal nav). `geometry.grade` itself is unchanged (NAV still reads `usableHosts`).

### 7. Manifest `tools` section + SuiteX Advanced tab
- **`tools/gen_manifest.lua` (MODIFY):** add a `TOOLS` table alongside `ROLES`. Each tool declares
  its launcher root(s); its shipped files are the require-closure (same machinery as roles), built
  for BOTH channels (min from `dist/`, dev from source), yielding `manifest.tools.beaconupdate =
  { files=..., entry="beaconupdate", ... }` in each of `manifest.lua` (min) and `manifest-dev.lua`
  (dev). `--check` covers it too.
- **`easyhover2_suitex.lua` (MODIFY):** in the Advanced tab (`frameAdv`), add a **"Beacon updater"**
  checkbox below `ui.devCheck`. On an install run, if ticked, after the role's files are written,
  fetch + write `manifest.<channel>.tools.beaconupdate.files` (channel chosen by the dev checkbox:
  off → min, on → dev — exactly the requested behavior). Install-time option, not a live toggle.
- The tool install reuses the Suite's existing fetch + `writeRelease` (checksum-verified) path.

## Bootstrapping consequence (documented, expected)

The remote-update mechanism cannot be deployed remotely — today's beacons have no update listener
and no token. The **first** rollout is manual: visit each of the 4 beacons once, install the new
beacon role (brings the update handler + the self-check fix), and set the shared token via `[U]`.
**All subsequent beacon patches are remote.** This is the same one-time trip the operator would make
now for the self-check fix; it also future-proofs the mesh.

## Testing (TDD)

- `beacon/update.lua`: `validToken` (empty/whitespace/valid); `encode`/`decode` round-trip + decode
  returns nil for GPS frames and wrong kinds; `accepts` — reject on token mismatch, reject when
  config token blank, reject non-command frames, accept on exact valid match.
- `beacon/runtime.lua`: `selfQuality` — a wide-flat mesh yields GOOD/small errorEst (regression
  mirroring the NAV fix); a clustered mesh yields POOR/large errorEst; < 4 hosts → hosts-only.
- `beacon/console.lua`: constellation row wording for GOOD/FAIR/POOR/waiting; token shown as
  set/unset, never echoed; `[U]` action mapping + `readToken` trimming.
- `tools/beaconupdate.lua`: refuse with invalid token; broadcasts exactly one command frame with the
  token (assert via mock modem); collects + sorts ack ids; returns responders within timeout;
  ignores non-ack frames.
- Manifest: `tools.beaconupdate` present in both channels with a non-empty file closure; `--check`
  IN SYNC after `node tools/build.mjs && bash tools/run_gen.sh`.
- SuiteX: pure checkbox→channel-variant selection (dev off → min files, dev on → dev files) and the
  "install tool when ticked" decision, tested without a terminal.
- Gates: source + dist headless suites (add new `tests.test_*` to both arrays) + e2e. New tool
  launcher/module ride the manifest; regen + build before the dist gate.

## Reuse
- Suite install/verify/config-sacred machinery (`easyhover2_suite.lua`: `Suite.main`, `fetch`,
  `writeRelease`, protected paths) — the beacon update and the tool install both lean on it.
- Manifest closure builder (`tools/closure.lua`, `tools/gen_manifest.lua` ROLES pattern → TOOLS).
- Frame codec conventions (`nav/comms/gpsproto`), mesh receiver (`nav/comms/receiver`), modem
  wrapping (`fcs/comms/modem`), mock modem (`tests/mocks/modem.lua`).
- Honest-metric wording + thresholds (`nav/ui/main.lua`), `geometry.hdop`/`dopQuality`.
- SuiteX Advanced-tab checkbox pattern (`ui.devCheck` in `easyhover2_suitex.lua`).

## Open items
None outstanding — fail-closed confirmed on both the beacon and the tool; suite-reuse, shared-token
guard, and ack-report all decided.
