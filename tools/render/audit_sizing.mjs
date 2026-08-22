// tools/render/audit_sizing.mjs
// Sizing lint for the cockpit UI: flag CLICKABLE/PICKABLE elements (buttons, switch buttons, picker
// dropdowns, lists) that are built at FULL/most-of-the-line width instead of being sized to their
// content via a shared helper. This is the checklist to clear before declaring a sizing sweep done --
// it is multiline-aware (catches wrapped calls the ad-hoc greps missed) and covers every width alias.
//
// It is a heuristic CHECKLIST, not an auto-fixer: some full-width elements are legitimate (a value
// readout bar, an overlay frame, a header/label, a progress bar). Review each hit; route the genuine
// buttons/fields through configkit.menuColumn / configkit.actionRow / btnfit.grid, or an explicit
// content-sized width. Usage: node tools/render/audit_sizing.mjs [uiDir]
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const ROOT = process.argv[2] || "ui";

// The interactive element constructors we care about (labels/frames/progressbars are excluded --
// they are frequently full-width on purpose).
const CREATE = /\b(addButton|addList|Picker\.make|switchbtn\.make)\b/;
// Full / most-of-the-line width: a bare width alias, or `<alias> - N`, or math.max/min wrapping one.
// The `(?<!\.)` guard skips struct-field reads like `geo[1].w` (btnfit output -- already compact),
// so those don't read as full-width.
const ALIASES = "w|fw|fiw|iw|half|rest|third|nameW|tw|availW";
const A = `(?<!\\.)(?:${ALIASES})\\b`;
const FULLW = new RegExp(
  `width\\s*=\\s*(?:${A}` +
  `|math\\.max\\([^)]*${A}` +
  `|math\\.min\\([^)]*${A}` +
  `|(?<!\\.)(?:${ALIASES})\\s*-)`
);
// Sanctioned helper internals -- these compute widths deliberately; don't flag them.
const SKIP_FILES = /(configkit|btnfit)\.lua$/;

function luaFiles(dir) {
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...luaFiles(p));
    else if (e.name.endsWith(".lua")) out.push(p);
  }
  return out;
}

let total = 0;
const byFile = {};
for (const file of luaFiles(ROOT)) {
  if (SKIP_FILES.test(file)) continue;
  const lines = readFileSync(file, "utf8").split("\n");
  for (let i = 0; i < lines.length; i++) {
    if (!CREATE.test(lines[i])) continue;
    // Accumulate ONLY this call's own text: from the create line up to the line that
    // closes it (`})`). A fixed N-line window would bleed into the NEXT element's props
    // (e.g. a following full-width Label), mis-attributing its width to this call.
    let callText = "";
    for (let j = i; j < Math.min(i + 8, lines.length); j++) {
      callText += " " + lines[j];
      if (lines[j].includes("})")) break;
    }
    if (!FULLW.test(callText)) continue;
    // Reviewed-legit full-width sites (value readouts, scrolling lists, status lamps) carry an
    // inline `audit:full-width-ok` marker so a clean run means "nothing UNREVIEWED", not "nothing wide".
    if (/audit:full-width-ok/.test(callText)) continue;
    const kind = (callText.match(CREATE) || [])[1];
    (byFile[file] ||= []).push({ line: i + 1, kind, text: lines[i].trim().slice(0, 90) });
    total++;
  }
}

const files = Object.keys(byFile).sort();
if (total === 0) {
  console.log("sizing audit: clean — no full-width buttons/fields/lists outside the helpers ✓");
} else {
  console.log(`sizing audit: ${total} candidate(s) across ${files.length} file(s)\n`);
  for (const f of files) {
    console.log(f.replace(/\\/g, "/"));
    for (const h of byFile[f]) console.log(`  ${String(h.line).padStart(4)}  [${h.kind}]  ${h.text}`);
    console.log("");
  }
  console.log("Review each: route real buttons/fields through configkit.menuColumn / configkit.actionRow");
  console.log("/ btnfit.grid, or give an explicit content-sized width. Legit full-width (value bars,");
  console.log("overlay frames, headers, progress bars) can stay.");
}
