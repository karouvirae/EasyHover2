// tools/render/build_pfd_artifact.mjs
// Wrap the redesigned PFD render (out/pfd.svg) in a single dark "monitor bezel" artifact page for
// review, matching the cockpit gallery's visual language. Keeps the SVG out of the model's context.
// Usage: node build_pfd_artifact.mjs <outDir> <out.html>
import { readFileSync, writeFileSync } from "node:fs";
const [, , outDir, outHtml] = process.argv;
const svg = readFileSync(`${outDir}/pfd.svg`, "utf8");

const html = `<title>PFD Big-Font Redesign</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@600;700&family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap">
<style>
  :root{
    --ground:#0a0d12; --panel:#12171f; --line:#232c3a; --line-soft:#1b232f;
    --ink:#d3dcea; --muted:#8695ab; --faint:#5d6b81; --accent:#7fcc19; --bezel:#04060a;
  }
  *{box-sizing:border-box}
  body{margin:0; background:var(--ground); color:var(--ink);
    font-family:"IBM Plex Sans",system-ui,sans-serif; line-height:1.55; -webkit-font-smoothing:antialiased;
    background-image:radial-gradient(1200px 640px at 50% -10%, #131a24 0%, var(--ground) 55%);}
  .wrap{max-width:960px; margin:0 auto; padding:52px 24px 80px}
  .eyebrow{font-family:"IBM Plex Mono",monospace; font-size:12px; letter-spacing:.22em;
    text-transform:uppercase; color:var(--accent); margin:0 0 12px}
  h1{font-family:"Chakra Petch",sans-serif; font-weight:700; font-size:clamp(28px,4.5vw,40px);
    line-height:1.05; margin:0 0 12px; text-wrap:balance}
  .lede{color:var(--muted); max-width:64ch; margin:0 0 6px; font-size:15.5px}
  .lede b{color:var(--ink); font-weight:600}
  .lede code{font-family:"IBM Plex Mono",monospace; color:var(--ink); font-size:.9em}

  .layout{display:grid; grid-template-columns:minmax(280px,1fr) minmax(240px,300px); gap:28px; align-items:start; margin-top:34px}
  @media (max-width:760px){ .layout{grid-template-columns:1fr} }
  figure{margin:0}
  .screen{background:var(--bezel); border:1px solid #263042; border-radius:9px; padding:12px;
    box-shadow:inset 0 0 0 1px #ffffff10, inset 0 0 46px #000, 0 30px 60px -34px #000}
  .screen svg{width:100%; height:auto; display:block; border-radius:2px}
  figcaption{margin-top:11px; font-family:"IBM Plex Mono",monospace; font-size:12px; color:var(--muted);
    letter-spacing:.03em; text-align:center}

  aside h2{font-family:"Chakra Petch",sans-serif; font-size:15px; letter-spacing:.02em; margin:0 0 12px;
    color:var(--ink)}
  .rows{border:1px solid var(--line); border-radius:10px; overflow:hidden; margin-bottom:22px}
  .row{display:grid; grid-template-columns:1fr auto auto; gap:10px; align-items:baseline;
    padding:9px 13px; border-top:1px solid var(--line-soft); font-family:"IBM Plex Mono",monospace; font-size:13px}
  .row:first-child{border-top:0}
  .row .k{color:var(--muted)} .row .was{color:var(--faint)} .row .now{color:var(--accent); font-weight:500;
    font-variant-numeric:tabular-nums}
  .row .arrow{color:var(--faint)}
  ul.steer{list-style:none; padding:0; margin:0}
  ul.steer li{font-family:"IBM Plex Mono",monospace; font-size:12.5px; color:var(--muted); padding:6px 0 6px 18px;
    position:relative; border-top:1px solid var(--line-soft)}
  ul.steer li:first-child{border-top:0}
  ul.steer li::before{content:"›"; position:absolute; left:2px; color:var(--accent)}
  footer{margin-top:44px; padding-top:18px; border-top:1px solid var(--line-soft);
    font-family:"IBM Plex Mono",monospace; font-size:12px; color:var(--faint); line-height:1.7}
  footer b{color:var(--muted); font-weight:500}
</style>

<div class="wrap">
  <p class="eyebrow">EasyHover 2 · PFD · Redesign · Gapless subpixel numbers</p>
  <h1>The whole readout, bigger</h1>
  <p class="lede">Everything you scan — the current <b>heading</b>, <b>SPD</b>, <b>ALT</b>, and the
    <b>TGT distance</b> — is now drawn as compact <b>2-cell-tall subpixel digits</b>: crisp, gapless,
    and small enough that they <b>all fit at once</b> with the attitude indicator kept near full
    height (17 rows, just −2). The tape scale and labels stay 1-cell. Faithful capture — these render
    identically in game.</p>
  <p class="lede">The earlier subpixel attempt was mush because it left one non-addressable teletext
    subpixel (the bottom-right) as a hole in every cell. The fix — reusing <code>panelgfx</code>'s
    inversion-aware cell renderer, the same one behind the FLIGHT panel's checkered borders — fills
    that subpixel by colour inversion, so the digits are gapless. (A monitor text-scale bump was
    ruled out: it would have halved the ADI's already-coarse horizon.)</p>

  <div class="layout">
    <figure>
      <div class="screen">${svg}</div>
      <figcaption>PFD · 2×2 monitors · 36×24 · scale 0.5 · demo state (hdg 045, SPD 145, TGT Pad-2 420 m, ALT 129)</figcaption>
    </figure>
    <aside>
      <h2>Row budget (36×24)</h2>
      <div class="rows">
        <div class="row"><span class="k">Heading tape</span><span class="was">3</span><span class="now"><span class="arrow">→</span> 3</span></div>
        <div class="row"><span class="k">Attitude (ADI)</span><span class="was">19</span><span class="now"><span class="arrow">→</span> 17</span></div>
        <div class="row"><span class="k">Readouts</span><span class="was">2</span><span class="now"><span class="arrow">→</span> 4</span></div>
      </div>
      <h2>What to steer</h2>
      <ul class="steer">
        <li>Digit size — 2-cell here; bigger, or right?</li>
        <li>ADI at 17 — good, or reclaim a row?</li>
        <li>Tape scale — bump those to 2-cell too?</li>
        <li>Readout order — SPD · TGT · ALT layout</li>
        <li>Digit shapes — any that read wrong?</li>
      </ul>
    </aside>
  </div>

  <footer>
    new: <b>ui/basalt/instruments/glyph.lua</b> (2-cell subpixel digit font on panelgfx's cell renderer)
    · rewritten <b>ui/basalt/pages/pfd.lua</b> (heading + SPD/TGT/ALT readouts) · ADI reused, 2 rows shorter<br>
    branch <b>redesign/pfd-bigfont</b> · not merged — this is for review. Tests + TDD before it ships.
  </footer>
</div>`;

writeFileSync(outHtml, html);
console.error("wrote " + outHtml + " (" + html.length + " bytes)");
