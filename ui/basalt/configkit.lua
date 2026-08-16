-- ui/basalt/configkit.lua
-- Shared helpers for the BIT/CONFIG page overhaul: label fitting, button-width splitting, a
-- plain-language tuning glossary, paging math for the help scroll (all PURE, Task 1) -- PLUS
-- (Task 2) the Basalt CHROME built on top: a shared action-button row and a scrollable help
-- screen, which the restructured config pages reuse. Requiring switchbtn is load-safe (it does no
-- Basalt/peripheral work at module load, same discipline as this module), so `require
-- ("ui.basalt.configkit")` still loads clean headless -- Basalt objects only ever flow through
-- M.actionRow/M.helpScreen's own parameters, never touched at module load.
local switchbtn = require("ui.basalt.switchbtn")

local M = {}

-- M.GLYPH: named button glyph/label constants (Feature 1). CC:Tweaked's font does NOT reliably
-- render ⟳/✓/✕, so every non-native action ships a short WORD by default; flip an entry to a real
-- glyph ONLY after confirming it renders in-game (same discipline as horizon.lua M.STYLE.subpixel).
-- BACK is the CC-native left arrow "\27", which always renders.
M.GLYPH = {
  BACK           = "\27",       -- ← (CC-native, safe)
  RESCAN         = "RE-SCAN",   -- word fallback; a glyph candidate can replace this after in-game confirm
  REFRESH        = "REFRESH",   -- word fallback
  CONFIRM_OK     = "OK",        -- no safe native ✓
  CONFIRM_CANCEL = "\27",       -- reuse BACK's ← for cancel
}

-- fitLabel(text, width): same behaviour as listpicker.formatLabel (strip one leading
-- "namespace:", then if still wider than width keep the TAIL prefixed with "~"; width nil/<=0 ->
-- strip only, no truncation). Delegates instead of duplicating the logic.
function M.fitLabel(text, width)
  return require("ui.basalt.listpicker").formatLabel(text, width)
end

-- splitWidths(total, n): divide `total` columns into `n` button widths, remainder distributed to
-- the leftmost cells (so a 14-col row of 3 buttons is 5/5/4). PRECONDITION: n <= total -- always
-- true for actionRow (a handful of buttons across >= 12 cols). Under that precondition this sums
-- EXACTLY to `total` with every width >= 1: base = floor(total/n) is >= 1, the first (total % n)
-- cells get base+1 and the rest get base -- no clamp needed, no rounding slop.
-- Degenerate n > total (more buttons than columns) returns n all-1 widths; the sum is then n, NOT
-- total -- over-subscribed by design. Callers that could hit this must handle the overflow
-- themselves (e.g. a scrollable row); this function does not silently claim to sum to total.
function M.splitWidths(total, n)
  local out = {}
  if not n or n <= 0 then return out end
  if n > total then
    for i = 1, n do out[i] = 1 end
    return out
  end
  local base = math.floor(total / n)
  local rem = total - base * n
  for i = 1, n do
    out[i] = base + ((i <= rem) and 1 or 0)
  end
  return out
end

-- M.GLOSSARY[id] = { title = "...", lines = { "...", ... } } -- plain-language tuning help,
-- content from the spec's "Glossary content" section, each line pre-trimmed to <= 14 columns
-- (the ~0.5-scale monitor width). helpLines() re-wraps these to the caller's actual width.
M.GLOSSARY = {
  gains = {
    title = "GAINS",
    lines = {
      "How firmly FCS", "corrects an", "axis to stay",
      "steady. Higher", "= tighter but", "twitchier.",
      "KP: reacts to", "error now",
      "KI: fixes slow", "drift",
      "KD: damps fast", "motion (anti-", "overshoot)",
    },
  },
  caps = {
    title = "CAP",
    lines = {
      "Max correction", "FCS may apply", "on an axis.",
      "Output safety", "clamp on the", "stabilizer.",
      "NOT the pilot", "leash.",
    },
  },
  feel = {
    title = "FEEL",
    lines = {
      "How craft", "answers your", "stick: ramp",
      "speed of held", "key + how far", "target leads",
      "ahead (lead/", "leash = your", "speed cap).",
      "Max lead lives", "here.",
    },
  },
  hoverduty = {
    title = "HOVER DUTY",
    lines = { "Baseline hover", "throttle." },
  },
  heave = {
    title = "HEAVE",
    lines = {
      "Lift band that", "preserves", "pitch/roll",
      "authority at", "the extremes.",
      "MIN/MAX = band", "edges.",
    },
  },
  modes = {
    title = "MODES",
    lines = {
      "PRECISION:", "flat-stable", "default.",
      "MAN: manual", "arrow-key", "tilt input.",
      "CRUISE: held", "forward", "throttle.",
      "CPL: coupled", "plane. Arrests",
      "side drift on", "release.",
      "DCPL: like",
      "CPL but side", "drift coasts",
      "(alt/att still", "held).",
    },
  },
  alt = {
    title = "ALT",
    lines = { "Holds altitude", "via heave/lift", "output." },
  },
  pitch = {
    title = "PITCH",
    lines = { "Nose up/down", "tilt about the", "side axis." },
  },
  roll = {
    title = "ROLL",
    lines = { "Bank left/", "right tilt", "about the", "fwd axis." },
  },
  yaw = {
    title = "YAW",
    lines = { "Heading spin", "left/right", "about the", "vertical axis." },
  },
  sway = {
    title = "SWAY",
    lines = { "Sideways", "left/right", "drift", "correction." },
  },
  surge = {
    title = "SURGE",
    lines = { "Forward/back", "drift", "correction." },
  },
}

-- words(lines): flatten a list of phrases into a flat word list (whitespace-split).
local function words(lines)
  local ws = {}
  for _, line in ipairs(lines) do
    for w in tostring(line):gmatch("%S+") do ws[#ws + 1] = w end
  end
  return ws
end

-- wrapWords(ws, width): greedy word wrap -- pack words onto a line while it fits `width`,
-- otherwise start a new one. A single word longer than `width` is HARD-BROKEN into width-sized
-- chunks (never left overlong) so every returned line is structurally guaranteed <= width.
local function wrapWords(ws, width)
  local out = {}
  local cur = ""
  for _, word in ipairs(ws) do
    local w = word
    while #w > width do
      if cur ~= "" then out[#out + 1] = cur; cur = "" end
      out[#out + 1] = w:sub(1, width)
      w = w:sub(width + 1)
    end
    if w ~= "" then
      if cur == "" then
        cur = w
      elseif #cur + 1 + #w <= width then
        cur = cur .. " " .. w
      else
        out[#out + 1] = cur
        cur = w
      end
    end
  end
  if cur ~= "" then out[#out + 1] = cur end
  return out
end

-- helpLines(entryId, width): GLOSSARY[entryId].title followed by its lines greedily
-- word-wrapped to `width`; unknown entryId -> {"(no help)"}. The title is passed through
-- fitLabel so it too is guaranteed <= width (matters once width drops below a title's length,
-- e.g. a narrow scroll region), and wrapWords hard-breaks any overlong word -- together every
-- line this returns is structurally <= width for ANY entryId/width, not just the current content.
function M.helpLines(entryId, width)
  local entry = M.GLOSSARY[entryId]
  if not entry then return { "(no help)" } end
  local w = (type(width) == "number" and width > 0) and width or 14
  local out = { M.fitLabel(entry.title, w) }
  for _, l in ipairs(wrapWords(words(entry.lines), w)) do
    out[#out + 1] = l
  end
  return out
end

-- scrollWindow(lines, offset, rows): pure paging for the help scroll -- up to `rows` lines
-- starting at `offset` (0-based), plus atTop/atBottom bounds for enabling/disabling UP/DOWN.
function M.scrollWindow(lines, offset, rows)
  offset = offset or 0
  rows = rows or 0
  local n = #lines
  local visible = {}
  for i = offset + 1, math.min(n, offset + rows) do
    if i >= 1 then visible[#visible + 1] = lines[i] end
  end
  return {
    visible = visible,
    atTop = offset <= 0,
    atBottom = (offset + rows) >= n,
  }
end

-- ===== Basalt chrome (Task 2) =====

-- M.actionRow(frame, {x, y, w}, specs) -> { buttons = {...}, setState(i, state) }
-- One horizontal row of switch-styled buttons whose widths come from splitWidths(w, #specs),
-- placed left-to-right starting at x. Each spec = { label, onClick, state? }; the label is passed
-- through fitLabel(label, cellWidth) so it never overruns its cell. Built with switchbtn.make for
-- consistent styling and a per-button set(state) -- default state is "off" unless spec.state is
-- given. setState(i, state) forwards to the i-th button's set().
function M.actionRow(frame, pos, specs)
  local widths = M.splitWidths(pos.w, #specs)
  local buttons = {}
  local px = pos.x
  for i, spec in ipairs(specs) do
    local width = widths[i] or 1
    local sw = switchbtn.make(frame, {
      x = px, y = pos.y, width = width, height = 1,
      text = M.fitLabel(spec.label, width),
    })
    local onClick = spec.onClick
    sw.button:onClick(function() if onClick then onClick() end end)
    sw.set(spec.state or "off")
    buttons[i] = sw
    px = px + width
  end
  local function setState(i, state)
    if buttons[i] then buttons[i].set(state) end
  end
  return { buttons = buttons, setState = setState }
end

-- M.helpScreen(basalt, frame, region, entryId) -> { apply = function(state) end }
-- A region screen (matches ui/basalt/region.lua's builder contract): stacks helpLines(entryId, w)
-- as labels, paged through scrollWindow, with a bottom actionRow of [UP][DN][<]. UP/DN adjust a
-- local scroll offset (clamped to the content, then re-render); "<" pops the region's nav. UP is
-- disabled at the top of the content and DN at the bottom (scrollWindow's atTop/atBottom), via
-- setState(..., "disabled"). apply() is a no-op -- like the other non-telemetry BIT/CONFIG
-- sub-menus (e.g. dtc.lua), this screen shows static help text, not live state.
function M.helpScreen(basalt, frame, region, entryId)
  local w, h = frame:getSize()
  local rowsAvailable = math.max(1, h - 1) -- bottom row reserved for the action row
  local lines = M.helpLines(entryId, w)
  local maxOffset = math.max(0, #lines - rowsAvailable)
  local offset = 0

  local lineLabels = {}
  for i = 1, rowsAvailable do
    lineLabels[i] = frame:addLabel({ x = 1, y = i, width = w, height = 1, autoSize = false, text = "" })
  end

  -- Forward-declared: render() closes over `row` (assigned below) and up()/down() (assigned
  -- below) close over render() -- all fine as upvalues once every local exists, but `row` itself
  -- must be declared before render() is DEFINED (not just before it's CALLED), or the reference
  -- inside render() would resolve to a global instead of this local.
  local row

  local function render()
    local win = M.scrollWindow(lines, offset, rowsAvailable)
    for i = 1, rowsAvailable do
      lineLabels[i]:setText(win.visible[i] or "")
    end
    row.setState(1, win.atTop and "disabled" or "off")
    row.setState(2, win.atBottom and "disabled" or "off")
  end

  local function up()
    offset = math.max(0, offset - 1)
    render()
  end
  local function down()
    offset = math.min(maxOffset, offset + 1)
    render()
  end

  row = M.actionRow(frame, { x = 1, y = h, w = w }, {
    { label = "UP", onClick = up },
    { label = "DN", onClick = down },
    { label = "<",  onClick = function() region:pop() end },
  })

  render()

  local function apply(_state) end

  return {
    apply = apply,
    elements = { lineLabels = lineLabels, row = row },
  }
end

return M
