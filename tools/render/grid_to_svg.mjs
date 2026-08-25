// tools/render/grid_to_svg.mjs
// Turn a captured CC:Tweaked cell grid (tools/render/render_panel -> /render_out.txt) into a
// faithful SVG: each cell is a bg rect at the true 6x9 cell aspect, printable glyphs are drawn in
// their fg colour, and CC drawing characters (128-159) become their exact 2x3 sub-pixel blocks.
// Also prints a colourless ASCII preview to stdout for a quick structural sanity check.
//
// Usage: node grid_to_svg.mjs <in render_out.txt> <out .svg>
import { readFileSync, writeFileSync } from "node:fs";

const DEFAULT = {
  "0": "f0f0f0", "1": "f2b233", "2": "e57fd8", "3": "99b2f2",
  "4": "dede6c", "5": "7fcc19", "6": "f2b2cc", "7": "4c4c4c",
  "8": "999999", "9": "4c99b2", "a": "b266e5", "b": "3366cc",
  "c": "7f664c", "d": "57a64e", "e": "cc4c4c", "f": "111111",
};

// CC:Tweaked renders bytes 16-31 as CP437-style arrow/triangle glyphs (used for BACK/scroll/mode cues).
const CTRL = { 16: "►", 17: "◄", 24: "↑", 25: "↓", 26: "→", 27: "←", 30: "▲", 31: "▼", 248: "°" };

const [, , inPath, outPath] = process.argv;
if (!inPath || !outPath) { console.error("usage: node grid_to_svg.mjs <in> <out.svg>"); process.exit(2); }

const raw = readFileSync(inPath, "latin1").split("\n");
let dimIdx = raw.findIndex((l) => /^\d+ \d+$/.test(l.trim()));
if (dimIdx < 0) { console.error("no dimension line found; file said:\n" + raw.slice(0, 3).join("\n")); process.exit(1); }
for (const l of raw.slice(0, dimIdx)) if (l.trim()) console.error("runner note: " + l);

const [W, H] = raw[dimIdx].trim().split(" ").map(Number);
const pal = { ...DEFAULT };
let rowStart = dimIdx + 1;
if ((raw[rowStart] || "").startsWith("PAL ")) {
  for (const tok of raw[rowStart].slice(4).trim().split(/\s+/)) {
    const [d, hex] = tok.split("=");
    if (d && hex) pal[d] = hex;
  }
  rowStart++;
}

const rows = [];
for (let r = 0; r < H; r++) {
  const line = raw[rowStart + r] ?? "";
  const [fg, bg, bytes] = line.split("\t");
  rows.push({
    fg: fg ?? "0".repeat(W),
    bg: bg ?? "f".repeat(W),
    ch: (bytes ? bytes.trim().split(/\s+/).map(Number) : []),
  });
}

// ---- ASCII preview (structure only) ----
const asciiLines = [];
for (const row of rows) {
  let s = "";
  for (let c = 0; c < W; c++) {
    const b = row.ch[c] ?? 32;
    if (b === 32) s += " ";
    else if (CTRL[b]) s += CTRL[b];
    else if (b >= 33 && b <= 126) s += String.fromCharCode(b);
    else if (b >= 128 && b <= 159) s += "░"; // drawing char -> light shade placeholder
    else s += "?";
  }
  asciiLines.push(s.replace(/\s+$/, ""));
}
console.log("+" + "-".repeat(W) + "+");
for (const l of asciiLines) console.log("|" + l.padEnd(W) + "|");
console.log("+" + "-".repeat(W) + "+  (" + W + "x" + H + " cells)");

// ---- SVG ----
const CW = 14, CH = 21; // 2:3 aspect ~ CC's 6x9 cell
const xml = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const parts = [];
parts.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${W * CW}" height="${H * CH}" viewBox="0 0 ${W * CW} ${H * CH}" font-family="'DejaVu Sans Mono','Consolas',monospace" shape-rendering="crispEdges">`);
parts.push(`<rect x="0" y="0" width="${W * CW}" height="${H * CH}" fill="#111111"/>`);

// bg rects, merged into horizontal runs of identical colour
for (let r = 0; r < H; r++) {
  const bg = rows[r].bg;
  let c = 0;
  while (c < W) {
    const d = bg[c] ?? "f";
    let c2 = c;
    while (c2 < W && (bg[c2] ?? "f") === d) c2++;
    parts.push(`<rect x="${c * CW}" y="${r * CH}" width="${(c2 - c) * CW}" height="${CH}" fill="#${pal[d]}"/>`);
    c = c2;
  }
}

// glyphs + drawing chars
const texts = [];
for (let r = 0; r < H; r++) {
  const { fg, ch } = rows[r];
  for (let c = 0; c < W; c++) {
    const b = ch[c] ?? 32;
    const color = "#" + (pal[fg[c] ?? "0"]);
    if (b === 32) continue;
    if (b === 7) {
      // CC bullet glyph -> a real filled circle (a status dot). Drawn geometrically, not as a font
      // glyph, so it is an actual circle at any scale (a 2x3 subpixel cell can't be round).
      parts.push(`<circle cx="${c * CW + CW / 2}" cy="${r * CH + CH / 2}" r="${Math.min(CW, CH) * 0.3}" fill="${color}"/>`);
    } else if (CTRL[b]) {
      texts.push(`<text x="${c * CW + CW / 2}" y="${r * CH + CH * 0.5}" fill="${color}" font-size="${Math.round(CH * 0.72)}" text-anchor="middle" dominant-baseline="central">${xml(CTRL[b])}</text>`);
    } else if (b >= 128 && b <= 159) {
      const n = b - 128;
      const sw = CW / 2, sh = CH / 3, x0 = c * CW, y0 = r * CH;
      // TL,TR,ML,MR,BL (bottom-right is bg via colour inversion, not drawn here)
      const cells = [[n & 1, 0, 0], [n & 2, 1, 0], [n & 4, 0, 1], [n & 8, 1, 1], [n & 16, 0, 2]];
      for (const [on, sx, sy] of cells) if (on) parts.push(`<rect x="${x0 + sx * sw}" y="${y0 + sy * sh}" width="${sw}" height="${sh}" fill="${color}"/>`);
    } else if (b >= 33 && b <= 126) {
      texts.push(`<text x="${c * CW + CW / 2}" y="${r * CH + CH * 0.5}" fill="${color}" font-size="${Math.round(CH * 0.82)}" text-anchor="middle" dominant-baseline="central">${xml(String.fromCharCode(b))}</text>`);
    }
  }
}
parts.push(...texts);
parts.push("</svg>");
writeFileSync(outPath, parts.join("\n"));
console.error("wrote " + outPath);
