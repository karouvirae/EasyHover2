-- ui/basalt/configkit.lua
-- Shared PURE helpers for the BIT/CONFIG page overhaul: label fitting, button-width splitting,
-- a plain-language tuning glossary, and paging math for the help scroll. NO Basalt access here --
-- every page's chrome (buttons/frames/region wiring) is built on top of this in later tasks, but
-- this module itself must be requirable and fully testable headless, with no peripheral access.
local M = {}

-- fitLabel(text, width): same behaviour as listpicker.formatLabel (strip one leading
-- "namespace:", then if still wider than width keep the TAIL prefixed with "~"; width nil/<=0 ->
-- strip only, no truncation). Delegates instead of duplicating the logic.
function M.fitLabel(text, width)
  return require("ui.basalt.listpicker").formatLabel(text, width)
end

-- splitWidths(total, n): divide `total` columns into `n` button widths summing to `total`, each
-- >= 1, remainder distributed to the leftmost cells (so a 14-col row of 3 buttons is 5/5/4).
function M.splitWidths(total, n)
  local out = {}
  if not n or n <= 0 then return out end
  local base = math.floor(total / n)
  local rem = total - base * n
  for i = 1, n do
    local w = base + ((i <= rem) and 1 or 0)
    out[i] = (w < 1) and 1 or w
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
-- otherwise start a new one. A single word longer than `width` is kept whole (never split).
local function wrapWords(ws, width)
  local out = {}
  local cur = ""
  for _, w in ipairs(ws) do
    if cur == "" then
      cur = w
    elseif #cur + 1 + #w <= width then
      cur = cur .. " " .. w
    else
      out[#out + 1] = cur
      cur = w
    end
  end
  if cur ~= "" then out[#out + 1] = cur end
  return out
end

-- helpLines(entryId, width): GLOSSARY[entryId].title followed by its lines greedily
-- word-wrapped to `width`; unknown entryId -> {"(no help)"}.
function M.helpLines(entryId, width)
  local entry = M.GLOSSARY[entryId]
  if not entry then return { "(no help)" } end
  local w = (type(width) == "number" and width > 0) and width or 14
  local out = { entry.title }
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

return M
