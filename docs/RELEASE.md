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

## Measured headroom (2026-08-11)

Summed `size` fields of the `ui` role's file entries (includes the identical,
never-minified 306,157-byte `basalt-full.lua` in both channels):

| channel | ui role total | delta vs dev |
|---|---|---|
| `manifest.lua` (min)     | 433,115 B (422.96 KB) | −179,633 B (−175.42 KB) |
| `manifest-dev.lua` (dev) | 612,748 B (598.39 KB) | baseline |

Free space on a 1 MB (1,048,576-byte) disk running the `ui` role:

| channel | free space |
|---|---|
| min | 1,048,576 − 433,115 = 615,461 B (601.03 KB) |
| dev | 1,048,576 − 612,748 = 435,828 B (425.61 KB) |

Net win: **+179,633 B (~175.4 KB) more free disk space** on the `ui` role when
running the default minified channel vs. the dev channel.

`fcs` role, same method, for reference: min 57,873 B (56.52 KB) vs dev 108,644 B
(106.10 KB), a −50,771 B (−49.58 KB) reduction.
