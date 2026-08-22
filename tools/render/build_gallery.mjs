// tools/render/build_gallery.mjs
// Assemble every rendered panel SVG (tools/render/out/*.svg) into one dark "cockpit gallery"
// artifact HTML, grouped by physical monitor surface. Keeps the SVGs out of the model's context.
// Usage: node build_gallery.mjs <outDir> <out.html>
import { readFileSync, writeFileSync } from "node:fs";

const [, , outDir, outHtml] = process.argv;
const svg = (id) => readFileSync(`${outDir}/${id}.svg`, "utf8");

const GROUPS = [
  { name: "PFD", sub: "2w×2h monitors · 36×24", panels: [["pfd", "PFD"]] },
  { name: "Overhead", sub: "2w×3h monitors · 36×38 · FLIGHT page + region drilldowns", panels: [
    ["flight", "FLIGHT — EMC over FCS"], ["flight_engine", "Engine config ▸ EMC region"],
    ["flight_calfuel", "Fuel calibration ▸ EMC region"], ["flight_params", "FCS parameters ▸ FCS region"] ] },
  { name: "NAV & BIT/CONFIG", sub: "2w×1h monitors · 36×10 · NAV page + its drilldowns", panels: [
    ["nav", "NAV"], ["hub", "BIT/CONFIG Hub"], ["tuning", "FCS TUNING"], ["mdb", "MDB-CONF"],
    ["uical", "UI CAL"], ["senscal", "SENS CAL"], ["senssource", "SENS SOURCE"], ["dtc", "DTC"], ["pfdrate", "PFD RATE"] ] },
  { name: "Entry panels", sub: "overlays over NAV · 36×10", panels: [
    ["waypointlist", "Waypoint list"], ["keypad_name", "Name keypad"],
    ["keypad_num", "Coord numpad"], ["listpicker", "List picker"] ] },
  { name: "UI-PC shell", sub: "advanced-computer terminal · 51×19", panels: [["config", "CONFIG"]] },
  { name: "A/P", sub: "1 monitor · 15×10", panels: [["ap", "A/P"]] },
];

const card = (id, title) => `
      <figure class="card">
        <div class="screen">${svg(id)}</div>
        <figcaption>${title}</figcaption>
      </figure>`;

const section = (g) => `
    <section class="group">
      <header class="grouphd">
        <h2>${g.name}</h2><span class="sub">${g.sub}</span>
      </header>
      <div class="grid">${g.panels.map(([id, t]) => card(id, t)).join("")}</div>
    </section>`;

const html = `<title>Cockpit Panel Gallery</title>
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
    font-family:"IBM Plex Sans",system-ui,sans-serif; line-height:1.5; -webkit-font-smoothing:antialiased;
    background-image:radial-gradient(1400px 700px at 50% -10%, #131a24 0%, var(--ground) 55%);}
  .wrap{max-width:1120px; margin:0 auto; padding:52px 24px 80px}
  .eyebrow{font-family:"IBM Plex Mono",monospace; font-size:12px; letter-spacing:.22em;
    text-transform:uppercase; color:var(--accent); margin:0 0 12px}
  h1{font-family:"Chakra Petch",sans-serif; font-weight:700; font-size:clamp(28px,4.5vw,42px);
    line-height:1.05; margin:0 0 10px; text-wrap:balance}
  .lede{color:var(--muted); max-width:66ch; margin:0 0 8px; font-size:15.5px}
  .lede code{font-family:"IBM Plex Mono",monospace; color:var(--ink); font-size:.9em}

  .group{margin-top:44px}
  .grouphd{display:flex; align-items:baseline; gap:14px; border-bottom:1px solid var(--line-soft);
    padding-bottom:10px; margin-bottom:22px}
  .grouphd h2{font-family:"Chakra Petch",sans-serif; font-weight:700; font-size:19px; margin:0; letter-spacing:.02em}
  .grouphd .sub{font-family:"IBM Plex Mono",monospace; font-size:12px; color:var(--faint)}

  .grid{display:grid; grid-template-columns:repeat(auto-fill,minmax(300px,1fr)); gap:22px; align-items:start}
  .card{margin:0; background:linear-gradient(180deg,#0e131b,#0a0e14); border:1px solid var(--line);
    border-radius:12px; padding:14px; box-shadow:0 24px 48px -30px #000, inset 0 1px 0 #ffffff08}
  .screen{background:var(--bezel); border-radius:7px; padding:10px; border:1px solid #263042;
    box-shadow:inset 0 0 0 1px #ffffff10, inset 0 0 40px #000}
  .screen svg{width:100%; height:auto; display:block; border-radius:2px}
  figcaption{margin-top:11px; font-family:"IBM Plex Mono",monospace; font-size:12.5px;
    color:var(--muted); letter-spacing:.03em; text-align:center}

  footer{margin-top:52px; padding-top:18px; border-top:1px solid var(--line-soft);
    font-family:"IBM Plex Mono",monospace; font-size:12px; color:var(--faint); line-height:1.7}
  footer b{color:var(--muted); font-weight:500}
</style>

<div class="wrap">
  <p class="eyebrow">EasyHover 2 · Cockpit</p>
  <h1>Every panel, rendered from code</h1>
  <p class="lede">Every current cockpit screen — pages, region drilldowns, BIT/CONFIG submenus, and the
    keypad / numpad / list entry panels — captured headless from the live Basalt source via CraftOS-PC.
    No screenshots. Each is a faithful white-on-black cell grid framed at <b>its parent surface's true
    resolution</b> (monitors at text scale 0.5; the UI-PC shell at native 51×19).</p>
  <p class="lede">Panels render at their <b><code>default / unbound</code></b> state (no live telemetry
    or saved config), so values read as placeholders — the layout, chrome, and text are exact.</p>
${GROUPS.map(section).join("\n")}
  <footer>
    tools/render/ · <b>rec_term.lua</b> → <b>render_panel.lua</b> → <b>grid_to_svg.mjs</b> · one CraftOS-PC boot<br>
    stray <b>?</b> glyphs are extended chars not yet mapped in the previewer — cosmetic, not in the capture.
  </footer>
</div>`;

writeFileSync(outHtml, html);
console.error("wrote " + outHtml + " (" + html.length + " bytes)");
