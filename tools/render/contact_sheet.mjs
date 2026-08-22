// tools/render/contact_sheet.mjs
// Build a single "contact sheet" HTML: every rendered panel SVG as a uniform, labelled thumbnail in
// a grid, so a whole-cockpit visual review is ONE screenshot (one model Read) instead of 22 separate
// PNGs. Each SVG is embedded as a base64 <img> in a fixed box with object-fit:contain, so panels of
// wildly different aspect ratios (square PFD, wide NAV, tall overhead) all sit in equal cells and the
// page height is exactly computable -- which the shell wrapper needs to size the headless screenshot.
//
// Usage: node tools/render/contact_sheet.mjs [id ...]
//   no args -> every out/*.svg, in ORDER (grouped by surface). Prints "<W> <H>" on the LAST stdout
//   line for contact_sheet.sh to pass as --window-size.
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, "out");

// Logical review order (grouped by surface); anything rendered but not listed is appended.
const ORDER = [
  // overhead (engine + FCS + drilldowns)
  "flight", "flight_engine", "flight_calfuel", "flight_params", "emc", "fcs",
  // BIT / CONFIG hub + sub-screens
  "bitconfig_hub", "uical", "uical_settings", "uical_devices", "tuning", "mdb",
  "senssource", "senscal", "fcssync",
  // PFD
  "pfd",
  // NAV
  "nav",
  // A/P
  "ap",
  // shared overlays / config
  "keypad", "keypad_num", "listpicker", "waypointlist", "config",
];

const COLS = 3;
const BOX_W = 360, BOX_H = 260, LABEL_H = 24, GAP = 14, PAD = 18;

function svgIds() {
  const present = readdirSync(OUT).filter(f => f.endsWith(".svg")).map(f => f.slice(0, -4));
  const cli = process.argv.slice(2);
  if (cli.length) return cli.filter(id => present.includes(id));
  const ordered = ORDER.filter(id => present.includes(id));
  const extra = present.filter(id => !ORDER.includes(id)).sort();
  return [...ordered, ...extra];
}

const ids = svgIds();
if (!ids.length) { console.error("contact_sheet: no SVGs in out/ -- run render_all.sh first"); process.exit(1); }

const cells = ids.map(id => {
  const svg = readFileSync(join(OUT, `${id}.svg`), "utf8");
  const b64 = Buffer.from(svg, "utf8").toString("base64");
  return `<figure class="cell">
      <img alt="${id}" src="data:image/svg+xml;base64,${b64}">
      <figcaption>${id}</figcaption>
    </figure>`;
}).join("\n");

const rows = Math.ceil(ids.length / COLS);
const W = PAD * 2 + COLS * BOX_W + (COLS - 1) * GAP;
const H = PAD * 2 + rows * (BOX_H + LABEL_H) + (rows - 1) * GAP;

const html = `<!doctype html><meta charset="utf-8">
<style>
  :root { color-scheme: dark; }
  body { margin:0; background:#0a0d12; padding:${PAD}px;
         font-family: "Consolas","DejaVu Sans Mono",monospace; }
  .grid { display:grid; grid-template-columns:repeat(${COLS}, ${BOX_W}px); gap:${GAP}px; }
  .cell { margin:0; display:flex; flex-direction:column; }
  .cell img { width:${BOX_W}px; height:${BOX_H}px; object-fit:contain; object-position:center;
              background:#000; border:1px solid #1c2530; box-sizing:border-box; }
  .cell figcaption { height:${LABEL_H}px; line-height:${LABEL_H}px; color:#5fd35f;
                     font-size:13px; letter-spacing:.5px; text-align:center; }
</style>
<div class="grid">
${cells}
</div>`;

writeFileSync(join(OUT, "contact_sheet.html"), html);
console.error(`contact sheet: ${ids.length} panels, ${COLS}x${rows} grid -> out/contact_sheet.html`);
console.log(`${W} ${H}`);
