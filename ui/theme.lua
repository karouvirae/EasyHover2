-- ui/theme.lua
-- Central cockpit COLOR SYSTEM. One place decides the uniform look: a hardcoded BLACK background on
-- every panel, a configurable font (foreground) colour, a configurable button colour, the NAV
-- waypoint/route cue colours, and an optional colourblind palette remap. Pure + headless-safe: no
-- Basalt/term access at module load. app.lua applies it globally via basalt.setTheme + per-term
-- setPaletteColour; the settings submenu (UI CAL -> UI SETTINGS) edits config.colors and re-applies.
--
-- State-feedback colours (e.g. ENG SW red->green) are set on elements DIRECTLY in their own code and
-- override the theme, so they keep working regardless of the button colour chosen here.
local M = {}

-- ===== the 14 pickable colours (config key -> CC colour slot). "gray" is CC lightGray (medium, so
-- it reads on black); "darkGray" is CC gray (the darker 0x4c4c4c). "lightRed" repurposes the unused
-- `orange` slot, recoloured to a bright red by PALETTE_BASE below. =====
M.COLOR_TO_SLOT = {
  lime = colors.lime, green = colors.green, blue = colors.blue, lightBlue = colors.lightBlue,
  cyan = colors.cyan, magenta = colors.magenta, white = colors.white, gray = colors.lightGray,
  darkGray = colors.gray, red = colors.red, lightRed = colors.orange, pink = colors.pink,
  purple = colors.purple, yellow = colors.yellow,
}

-- Ordered { key, label } for the pickers (labels are what the user reads).
M.COLOR_CHOICES = {
  { "lime", "LIME" }, { "green", "GREEN" }, { "blue", "BLUE" }, { "lightBlue", "LIGHT BLUE" },
  { "cyan", "CYAN" }, { "magenta", "MAGENTA" }, { "white", "WHITE" }, { "gray", "GRAY" },
  { "darkGray", "DARK GRAY" }, { "red", "RED" }, { "lightRed", "LIGHT RED" }, { "pink", "PINK" },
  { "purple", "PURPLE" }, { "yellow", "YELLOW" },
}

-- CC:T default RGBs (dan200 Colour.java) -- needed to compute the grayscale colourblind palette.
M.DEFAULT_RGB = {
  [colors.white] = 0xf0f0f0, [colors.orange] = 0xf2b233, [colors.magenta] = 0xe57fd8,
  [colors.lightBlue] = 0x99b2f2, [colors.yellow] = 0xdede6c, [colors.lime] = 0x7fcc19,
  [colors.pink] = 0xf2b2cc, [colors.gray] = 0x4c4c4c, [colors.lightGray] = 0x999999,
  [colors.cyan] = 0x4c99b2, [colors.purple] = 0xb266e5, [colors.blue] = 0x3366cc,
  [colors.brown] = 0x7f664c, [colors.green] = 0x57a64e, [colors.red] = 0xcc4c4c, [colors.black] = 0x111111,
}

-- Base palette overrides applied in every mode: recolour the repurposed `orange` slot to a bright
-- "light red" so lightRed is visibly distinct from red (0xcc4c4c).
M.PALETTE_BASE = { [colors.orange] = 0xff6a6a }

M.DEFAULTS = { font = "green", button = "gray", wpt = "yellow", rt = "blue", colorblind = "none" }

-- ===== colourblind palette remaps (setPaletteColour slot -> rgb). First pass, refinable: each
-- deficiency FAMILY gets an appropriate colourblind-safe recolour of the confusable hues using
-- Okabe-Ito-derived values; total/partial colour blindness gets a luminance grayscale. =====
-- CC:Tweaked Lua 5.1 has no bitwise operators -- use plain arithmetic for RGB byte packing.
local function unpackRGB(v) return math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256 end
local function packRGB(r, g, b) return r * 65536 + g * 256 + b end
local function lumOf(rgb)
  local r, g, b = unpackRGB(rgb)
  return math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
end
local function grayscale(blend)
  local out = {}
  for slot, rgb in pairs(M.DEFAULT_RGB) do
    if slot ~= colors.black then
      local y = lumOf(rgb)
      if blend and blend < 1 then
        local function mix(a) return math.floor(a + (y - a) * blend) end
        local r, g, b = unpackRGB(rgb)
        out[slot] = packRGB(mix(r), mix(g), mix(b))
      else
        out[slot] = packRGB(y, y, y)
      end
    end
  end
  return out
end

-- Red-green safe: push red -> vermillion, green -> bluish-green, lime -> safe yellow, keep the
-- blue/orange axis (which red-green types see fine). Helps protan* and deutan* families.
local RED_GREEN = {
  [colors.red] = 0xd55e00, [colors.green] = 0x009e73, [colors.lime] = 0xf0e442,
  [colors.orange] = 0xe69f00, [colors.magenta] = 0xcc79a7, [colors.pink] = 0xcc79a7,
}
-- Blue-yellow safe: separate blue/cyan and yellow along a distinguishable axis for tritan* types.
local BLUE_YELLOW = {
  [colors.blue] = 0x0072b2, [colors.cyan] = 0x56b4e9, [colors.lightBlue] = 0x56b4e9,
  [colors.yellow] = 0xf0e442, [colors.orange] = 0xe69f00,
}

M.COLORBLIND = {
  none = {},
  protanopia = RED_GREEN, protanomaly = RED_GREEN,
  deuteranopia = RED_GREEN, deuteranomaly = RED_GREEN,
  tritanopia = BLUE_YELLOW, tritanomaly = BLUE_YELLOW,
  achromatopsia = grayscale(1.0), achromatomaly = grayscale(0.6),
}

M.COLORBLIND_MODES = {
  { "none", "NONE" }, { "protanopia", "PROTANOPIA" }, { "protanomaly", "PROTANOMALY" },
  { "deuteranopia", "DEUTERANOPIA" }, { "deuteranomaly", "DEUTERANOMALY" },
  { "tritanopia", "TRITANOPIA" }, { "tritanomaly", "TRITANOMALY" },
  { "achromatopsia", "ACHROMATOPSIA" }, { "achromatomaly", "ACHROMATOMALY" },
}

-- ===== resolution =====

-- Resolve a role ("font"|"button"|"wpt"|"rt") to a CC colour slot, defaulting on unknown/missing.
function M.resolve(colorsCfg, role)
  colorsCfg = colorsCfg or {}
  local name = colorsCfg[role] or M.DEFAULTS[role]
  return M.COLOR_TO_SLOT[name] or M.COLOR_TO_SLOT[M.DEFAULTS[role]]
end

-- Merged palette overrides to write (base + the selected colourblind mode).
function M.paletteFor(colorsCfg)
  colorsCfg = colorsCfg or {}
  local pal = {}
  for slot, rgb in pairs(M.PALETTE_BASE) do pal[slot] = rgb end
  for slot, rgb in pairs(M.COLORBLIND[colorsCfg.colorblind or "none"] or {}) do pal[slot] = rgb end
  return pal
end

-- Basalt theme: BLACK background on every element/nesting depth, font colour foreground, buttons on
-- the button colour. The Container node references itself so ARBITRARY frame nesting stays black
-- (this is what kills the old cyan default-theme leak on the overhead's nested region frames).
function M.buildTheme(colorsCfg)
  local FONT = M.resolve(colorsCfg, "font")
  local BUTTON = M.resolve(colorsCfg, "button")
  local BLACK = colors.black
  local btn = { background = BUTTON, foreground = FONT, states = { clicked = { background = BUTTON, foreground = FONT } } }
  local container = {
    default = { background = BLACK, foreground = FONT },
    background = BLACK, foreground = FONT,
    Button = btn, Label = { foreground = FONT }, Input = { background = BLACK, foreground = FONT },
  }
  container.Container = container -- any depth of nesting resolves to the same black theme
  return {
    default = { background = BLACK, foreground = FONT },
    BaseFrame = {
      background = BLACK, foreground = FONT,
      Button = btn, Label = { foreground = FONT }, Input = { background = BLACK, foreground = FONT },
      Container = container,
    },
  }
end

-- ===== application (the only impure seams) =====

-- Set the global Basalt theme from config.colors. The theme plugin's API (setTheme/getTheme) is
-- reached via basalt.getAPI("theme"), NOT as basalt.setTheme. Elements pick the theme up at creation
-- (applyTheme during init), so call this BEFORE building frames/pages.
function M.applyTheme(basalt, colorsCfg)
  local api = basalt and basalt.getAPI and basalt.getAPI("theme")
  if api and api.setTheme then api.setTheme(M.buildTheme(colorsCfg)) end
end

-- Write the palette overrides onto ONE term/monitor object (has setPaletteColour/Colour).
function M.applyPalette(term, colorsCfg)
  if not term then return end
  local set = term.setPaletteColour or term.setPaletteColor
  if not set then return end
  for slot, rgb in pairs(M.paletteFor(colorsCfg)) do set(slot, rgb) end
end

return M
