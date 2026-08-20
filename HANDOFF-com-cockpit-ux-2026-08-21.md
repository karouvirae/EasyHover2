# HANDOFF — CoM offset + UI CAL/WPT keypad — 2026-08-21

Resume point. `main` is pushed. HEAD **`b4dbc53`**.

## Session-start setup

- Skills: `using-superpowers`, **`dev-permissions`** (CraftOS + Firecrawl grants),
  **`minecraft-mod-docs`**. Basalt **2.0 full only** — not 2.5.
- EH2 checkpoints: `eh2-com-offset-checkpoint`, `eh2-uical-wpt-keypad-checkpoint`,
  `eh2-engine-latch-mode-checkpoint` (UI CAL labels now fixed), `eh2-nav-menu-design`.
- Repo: `C:\Users\m-kri\Claude Code\EasyHover2`.
- **SDD:** OpenCode Task tool only has `general` / `explore`. For multi-step EH2
  work still write a spec+plan and dispatch `general` implementer/reviewer seats
  (or say so if staying in-session). This session implemented in-session TDD;
  did not run SDD task reviews.

## Shipped this session (all on `main`)

| Commit | What |
|--------|------|
| `58b1ac9` | UI CAL latch labels + pinned BACK; WPT form keypad; DEL clears draft |
| `f2c405f` | CoM mixer + Auto COM trim in FCS TUNING |
| `085ffcd` | SPAN split → SP FWD + SP LAT (rectangle lift square) |
| `750749d` | keypad title/value contrast (insufficient — Label still transparent) |
| `b4dbc53` | keypad buffer is a **Button** bar (Basalt 2.0 Label does not paint bg) |

Gates at last ship: 1152/0 source+dist, e2e green.

Specs: `docs/superpowers/specs/2026-08-21-eh2-com-offset-design.md`,
`docs/superpowers/specs/2026-08-21-eh2-uical-wpt-keypad.md`.

## USER in-world

1. Suite update **UI + FCS** (COM is FCS-side too); **NAV** if WPT keypad:
   `wget run https://raw.githubusercontent.com/maar-10/EasyHover2/main/easyhover2_suite.lua`
2. UI CAL DEVICES: MODE / SIDE vs BLOCK+FEED, `<` BACK on screen. Latch still
   needs the in-world Powered Latch + reboot UI PC (writer chosen at construct).
3. WPT: MAN/EDIT → white bar under `NAME` is the buffer; HERE = `hereN`; DEL
   must not resurrect.
4. COM: measure SP FWD (C→front/back edge) and SP LAT (C→left/right edge),
   SAVE, **reboot FCS**. AUTO optional (prereqs on the WAIT lamp).

## NEXT (not done)

- In-world confirm keypad buffer + COM mix / Auto COM.
- If Auto COM is rough: dwell/tilt/climbHeight in `fcs/comauto.lua`.
- A/P still a separate future build.
- v1 CoM limits: lift mix only (no lateral/surge CoM), no vertical CoM.
