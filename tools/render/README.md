# tools/render — Basalt/CC:T panels → faithful images

Turns the **real** EasyHover 2 Basalt UI (the same Lua that runs in-game) into faithful images and a
browser gallery, **headless — no Minecraft, no screenshots**. This is the clean base for the cockpit
visual redesign. Companion: the `basalt-render` skill (`~/.claude/skills/basalt-render/`).

## Why it's faithful

A Basalt UI's entire visual output is just three things, all captured from the live code:
1. the **character-cell grid** — glyph + foreground + background per cell,
2. the **16-colour palette** (CC:T default, plus any `setPaletteColour` overrides),
3. the **cell aspect** (6×9, tall — not square).

We mount a real panel in CraftOS-PC into a *recording terminal* that stores exactly what Basalt
`blit`s, then draw that grid to SVG. Same code as in-game ⇒ same picture.

## The pipeline (formats chain)

```
EH2 Basalt Lua            CraftOS-PC (headless)           Node                     Node
(ui/basalt/**.lua)  ──►   render_panel.lua  ──►  /render_out_<id>.txt  ──►  out/<id>.svg  ──►  out/gallery.html
   source panels          rec_term.lua captures        grid dump          grid_to_svg.mjs     build_gallery.mjs
                          the cell grid + palette      (txt, per panel)   (SVG, per panel)    (one HTML, all SVGs inline)
                                                                                │
                                                              headless Edge     ▼
                                                              render_png.sh ─► out/<id>.png  (raster, for model self-review)
```

| Format | What it is | Where |
|--------|-----------|-------|
| `.lua` (source) | the actual panels being rendered | `ui/basalt/**` (not here) |
| `.txt` | raw captured cell grid: `W H`, optional `PAL`, then rows of `fg⇥bg⇥bytes` | `out/<id>.txt` |
| `.svg` | one faithful panel image (bg rects + glyphs + 2×3 drawing-char sub-pixels) | `out/<id>.svg` |
| `.html` | the gallery — every SVG inlined, self-contained, dark monitor bezels | `out/gallery.html` |
| `.png` | raster of a panel's SVG via headless Edge — **the model can open/view these** | `out/<id>.png` |

## Files

- **`rec_term.lua`** — recording CC:T terminal: implements the term surface Basalt drives
  (`blit`/`write`/`clear`/`setCursorPos`/colour/palette) and stores the grid + palette overrides.
- **`render_panel.lua`** — CraftOS runner. Holds the **RECIPES registry** (every panel: its monitor
  size + how to `build` it + optional `postBuild` nav + `state`) and mounts each the way the real app
  does. `EH2_RENDER_PANEL="all"` renders every panel in one boot.
- **`grid_to_svg.mjs`** — Node: one `.txt` grid → one faithful `.svg` (+ an ASCII preview to stdout).
- **`build_gallery.mjs`** — Node: all `out/*.svg` → one `gallery.html`, grouped by monitor surface.
  Reads the SVGs from disk so they never need to pass through a model's context.
- **`render.sh`** — render ONE panel: `bash tools/render/render.sh <panel> <cols> <rows>`.
- **`render_all.sh`** — render EVERY panel in one boot, then generate all SVGs.
- **`render_png.sh`** — rasterise SVG(s) → PNG via **headless Microsoft Edge** so the model can *view*
  them: `bash tools/render/render_png.sh <id>` (or no arg / `all` for every panel). Reads the `.svg`,
  wraps it on the cockpit ground, screenshots at 2× into `out/<id>.png`. **This is how the model does
  visual self-review** — after generating, `Read` the PNG to see the panel as an image and catch
  anything that deviates from intent, before showing the user.
- **`out/`** — committed clean base: per-panel `.txt` + `.svg` + `.png`, and `gallery.html`.

## Regenerate

```bash
bash tools/render/render_all.sh                                   # all panels -> out/*.{txt,svg}
node tools/render/build_gallery.mjs tools/render/out tools/render/out/gallery.html
bash tools/render/render_png.sh all                               # all panels -> out/*.png (for model self-review)
```

Prereqs: CraftOS-PC (see the `dev-permissions` skill) for the render; **Microsoft Edge** (Chromium) for
the PNG step. `out/gallery.html` is self-contained — open it in a browser, or publish it as an Artifact
(load `artifact-design` first). To self-review a single panel: `bash tools/render/render_png.sh <id>`
then open `out/<id>.png`.

## Correctness rules (do not skip — all hard-won)

1. **Mount like the real app** (`ui/basalt/app.lua` `showScreen`), never a bare BaseFrame:
   `base=createFrame(); base:setTerm(rec); child=base:addFrame{x=1,y=1,width=W,height=H}; page.build(basalt, child, …)`
   then ~6 `basalt.update("timer",-1)` passes.
   - No `setTerm` ⇒ nested labels `wrapText`-wrap to width 1.  No child Frame ⇒ Basalt's default WHITE
     theme instead of the real white-on-black.
2. **`Label:render` runs `wrapText`, which strips leading spaces.** Space-padded centering only renders
   centered when the row also has non-space content (e.g. the PFD attitude craft is centered at level,
   but shifts left off-level — a real latent EH2 bug, not a render error). Fix such centering by
   per-cell x, not leading spaces.
3. **Cell size** (CC `ServerMonitor.java`, text scale 0.5):
   `cols=round((Wblocks−0.3125)/(0.5·6/64))`, `rows=round((Hblocks−0.3125)/(0.5·9/64))`.

## Panel → surface resolution map (confirmed)

| Surface | Monitors | Cells | Panels |
|---------|----------|-------|--------|
| PFD | 2w×2h | **36×24** | `pfd` |
| Overhead | 2w×3h | **36×38** | `flight`, `flight_engine`, `flight_calfuel`, `flight_params` (FLIGHT page + region drilldowns) |
| NAV + BIT/CONFIG | 2w×1h | **36×10** | `nav`, `hub`, `tuning`, `mdb`, `uical`, `senscal`, `senssource`, `dtc`, `pfdrate` (all NAV sub-menus) |
| Entry overlays | over NAV | **36×10** | `waypointlist`, `keypad_name`, `keypad_num`, `listpicker` |
| UI-PC shell | terminal | **51×19** | `config` (native, no monitor scaling) |
| A/P | 1×1 | **15×10** | `ap` |

Panels render at **default / unbound state** (placeholder values): layout, chrome, and text are exact;
live values are `--`/`0%`. Feed a recipe's `state`/`runtime` for populated captures.
