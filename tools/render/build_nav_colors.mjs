// Build a self-contained swatch board of the NAV redesign rendered on every list-bg colour slot.
// Usage: node tools/render/build_nav_colors.mjs
import { readFileSync, writeFileSync } from "node:fs";

const OUT = "tools/render/out";
// slot -> {hex (theme RGB), note}. Order roughly best-first; collisions flagged.
const SLOTS = [
  ["gray",      "4C4C4C", ""],
  ["lightGray", "999999", ""],
  ["cyan",      "4C99B2", ""],
  ["blue",      "3366CC", "hides the blue RT selection"],
  ["lightBlue", "99B2F2", ""],
  ["red",       "CC4C4C", ""],
  ["orange",    "F2B233", ""],
  ["brown",     "FF6A6A", "brown slot is repurposed → red in the theme"],
  ["magenta",   "E57FD8", "close to A/P’s reserved pink/purple"],
  ["lime",      "7FCC19", ""],
  ["white",     "F0F0F0", ""],
  ["yellow",    "DEDE6C", "hides the yellow WPT selection"],
  ["green",     "57A64E", "hides the green unselected text"],
  ["black",     "111111", "same as the panel — no distinction"],
];

const b64 = (name) => readFileSync(`${OUT}/nav_bg_${name}.png`).toString("base64");

const cards = SLOTS.map(([name, hex, note]) => `
    <figure class="card${note ? " flag" : ""}">
      <div class="shot"><img src="data:image/png;base64,${b64(name)}" alt="NAV list on ${name}"></div>
      <figcaption>
        <span class="sw" style="background:#${hex}"></span>
        <span class="name">${name}</span>
        <span class="hex">#${hex}</span>
        ${note ? `<span class="note">${note}</span>` : ""}
      </figcaption>
    </figure>`).join("");

const html = `<title>NAV List Swatches</title>
<style>
  :root{
    --bg:#0c0e0d; --panel:#151917; --panel2:#1c211e; --edge:#2a312d;
    --ink:#d6ded8; --dim:#8a938c; --accent:#57a64e; --menu:#5b8dd6; --func:#e0912f; --warn:#c9b06b;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);
    font-family:"IBM Plex Sans",system-ui,sans-serif;line-height:1.5;
    padding:clamp(1.2rem,4vw,3rem)}
  .wrap{max-width:1100px;margin:0 auto}
  h1{font-size:clamp(1.5rem,3.5vw,2.1rem);margin:0 0 .3rem;font-weight:600;letter-spacing:-.01em}
  .lede{color:var(--dim);margin:0 0 1.6rem;max-width:60ch}
  .legend{display:flex;flex-wrap:wrap;gap:.5rem .9rem;margin:0 0 2rem;padding:.85rem 1rem;
    background:var(--panel);border:1px solid var(--edge);border-radius:10px;
    font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.82rem}
  .legend span{white-space:nowrap;color:var(--dim)}
  .legend b{font-weight:600}
  .k-menu{color:var(--menu)} .k-func{color:var(--func)} .k-wpt{color:#e5d84c} .k-rt{color:#6f8fe0} .k-fg{color:var(--accent)}
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:1rem}
  .card{margin:0;background:var(--panel);border:1px solid var(--edge);border-radius:10px;overflow:hidden;
    display:flex;flex-direction:column}
  .card.flag{border-color:#4a463a}
  .shot{background:#111;padding:0;line-height:0}
  .shot img{width:100%;height:auto;display:block;image-rendering:auto}
  figcaption{display:grid;grid-template-columns:auto auto 1fr;align-items:center;gap:.5rem;
    padding:.6rem .8rem;font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.85rem}
  .sw{width:1rem;height:1rem;border-radius:3px;border:1px solid rgba(255,255,255,.18)}
  .name{font-weight:600;color:var(--ink)}
  .hex{color:var(--dim);font-size:.78rem}
  .note{grid-column:1/-1;color:var(--warn);font-size:.76rem;margin-top:.15rem}
  footer{margin-top:2rem;color:var(--dim);font-size:.82rem;max-width:70ch}
</style>
<div class="wrap">
  <h1>NAV List Swatches</h1>
  <p class="lede">The redesigned NAV strip (36&times;10) on every available list-background slot, to pick which one best sets the waypoint/route list apart. Pink &amp; purple are omitted &mdash; reserved for A/P.</p>
  <div class="legend">
    <span><b class="k-menu">[ &nbsp;]</b> menu button</span>
    <span><b class="k-func">[ &nbsp;]</b> function</span>
    <span><b class="k-func">{ &nbsp;}</b> filter (cycles)</span>
    <span><b class="k-fg">&#9658;</b> list item</span>
    <span><b class="k-wpt">&#9658; &lt;WPT&gt;</b> selected waypoint</span>
    <span><b class="k-rt">&#9658; &lt;RT&gt;</b> selected route</span>
  </div>
  <div class="grid">${cards}
  </div>
  <footer>Each render shows all three list text states at once (unselected&nbsp;green, WPT-selected&nbsp;yellow, RT-selected&nbsp;blue) so contrast is judgeable on every ground &mdash; in the real list only one type shows per tab. Slots flagged in amber collide with a text colour or are otherwise constrained.</footer>
</div>`;

writeFileSync(`${OUT}/nav_swatches.html`, html);
console.error(`wrote ${OUT}/nav_swatches.html (${html.length} bytes)`);
