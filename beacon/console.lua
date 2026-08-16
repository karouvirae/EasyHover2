-- beacon/console.lua
-- The beacon's screen: plain `term`, keyboard-driven, no Basalt. A beacon runs on a BASIC computer,
-- which has no mouse, so `mouse_click` never fires there -- a button panel would be inert. Two rules
-- fall out (both learned in EH1's gps_beacon):
--   * EVERY ACTION IS A SINGLE KEYPRESS (nothing to point at).
--   * SEVERITY LIVES IN THE TEXT, NOT THE COLOUR -- a basic terminal is monochrome, so a red
--     MISMATCH and a green OK render identically. Colour is a hint added only when the terminal has
--     it, and never carries meaning alone.
-- render() is PURE (cfg + model in, rows out) so the whole screen is testable without a terminal.
local Console = {}

--- A keypress asks for an action; the caller performs the side effect (keeps this testable).
Console.ACTIONS = { p = "setPosition", e = "toggleEnabled", v = "verify", u = "setToken", q = "quit" }

function Console.actionFor(key)
  if type(key) ~= "string" then return nil end
  return Console.ACTIONS[key:lower()]
end

local function validPos(p)
  return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

local function pad(text, width)
  text = tostring(text or "")
  if #text > width then return text:sub(1, width) end
  return text
end

-- Wrap a sentence to width, indented, so a problem never runs off-screen unread.
local function wrap(text, width, indent, out)
  local prefix, line = indent or "", nil
  for word in tostring(text):gmatch("[^ ]+") do
    if line == nil then line = word
    elseif #prefix + #line + 1 + #word <= width then line = line .. " " .. word
    else out[#out + 1] = prefix .. line; line = word; prefix = (indent or "") .. "  " end
  end
  if line then out[#out + 1] = prefix .. line end
end

--- The whole screen as a list of { text, tone } rows, plus rows.footer. tone is a colour HINT
--- ("normal"|"good"|"bad"|"dim"); the text stands alone. model = { selfCheck, constellation, peers,
--- seq } as produced by beacon.runtime.
function Console.render(cfg, model, width)
  cfg = cfg or {}
  model = model or {}
  width = width or 51
  local rows = {}
  local function row(text, tone) rows[#rows + 1] = { text = pad(text, width), tone = tone } end

  row(("EasyHover2 GPS   %s"):format(tostring(cfg.id or "?")), "normal")

  -- position
  if validPos(cfg.pos) then
    row(("position  %d %d %d"):format(math.floor(cfg.pos.x), math.floor(cfg.pos.y), math.floor(cfg.pos.z)), "good")
  else
    row("position  NOT SET -- press [P] before enabling", "bad")
  end

  -- the self-check gets the loudest line, in WORDS
  local sc = model.selfCheck or { ok = true, checked = 0, mismatches = {} }
  if (sc.checked or 0) == 0 then
    row("self check  no peers heard yet", "dim")
  elseif sc.ok then
    row(("self check  OK (%d peer%s consistent)"):format(sc.checked, sc.checked == 1 and "" or "s"), "good")
  else
    local n = #(sc.mismatches or {})
    row(("self check  !! MISMATCH on %d beacon%s !!"):format(n, n == 1 and "" or "s"), "bad")
    for _, m in ipairs(sc.mismatches or {}) do
      row(("  %s: measured %.1f vs config %.1f (%.1f off)"):format(
        tostring(m.id), m.measured or 0, m.expected or 0, m.delta or 0), "bad")
    end
  end

  row(("-"):rep(width), "dim")

  -- the constellation, graded HONESTLY on HORIZONTAL geometry (matches the NAV): a wide, flat spread
  -- is GOOD even though gps.locate() would call it "coplanar" -- only horizontal dilution matters for
  -- a hovercraft. Under 4 hosts we are still gathering peers, so say "waiting", not "UNUSABLE".
  local sq = model.selfQuality or { hosts = 0 }
  if (sq.hosts or 0) < 4 then
    row(("constellation  %d of 4   waiting"):format(sq.hosts or 0), "dim")
  else
    local q = sq.quality or 0
    local label = (q >= 0.75 and "GOOD") or (q >= 0.4 and "FAIR") or "POOR"
    local err = sq.errorEst and ("  ~%d blk"):format(math.floor(sq.errorEst + 0.5)) or ""
    row(("constellation  %d of 4   %s%s"):format(sq.hosts, label, err),
      (q >= 0.75 and "good") or (q >= 0.4 and "normal") or "bad")
  end

  -- the 4-beacon list: this beacon, then heard peers (sorted for a stable screen)
  if validPos(cfg.pos) then
    row(("  * %s  %d %d %d  (this one)"):format(tostring(cfg.id or "?"),
      math.floor(cfg.pos.x), math.floor(cfg.pos.y), math.floor(cfg.pos.z)), "dim")
  end
  local peers = model.peers or {}
  local ids = {}
  for id in pairs(peers) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  for _, id in ipairs(ids) do
    local p = peers[id]
    local age = (p.ageMs or 0) / 1000
    if validPos(p.pos) then
      row(("  + %s  %d %d %d  %.1fs"):format(tostring(id),
        math.floor(p.pos.x), math.floor(p.pos.y), math.floor(p.pos.z), age), "good")
    else
      row(("  + %s  (no range)"):format(tostring(id)), "dim")
    end
  end

  row(("-"):rep(width), "dim")
  local peerCount = 0
  for _ in pairs(peers) do peerCount = peerCount + 1 end
  row(("broadcasts %d   peers %d"):format(model.seq or 0, peerCount), "dim")

  rows.footer = {
    { text = "[P] set position", tone = "normal" },
    { text = ("[E] enabled: %s"):format(cfg.enabled ~= false and "YES" or "NO"),
      tone = cfg.enabled ~= false and "good" or "bad" },
    { text = "[V] verify now", tone = "normal" },
    { text = ("[U] update token: %s"):format(cfg.updateToken and "SET" or "unset"),
      tone = cfg.updateToken and "good" or "dim" },
    { text = "[Q] quit to shell", tone = "dim" },
  }
  return rows
end

-- ---------------------------------------------------------------- drawing

local TONES = { normal = colours.white, good = colours.lime, bad = colours.red, dim = colours.lightGrey }

--- Paint the rendered rows. Colour only when the terminal has it; the text already carries meaning,
--- so a monochrome beacon loses only decoration.
function Console.draw(rows, width, height)
  local colour = term.isColour and term.isColour()
  term.setBackgroundColour(colours.black)
  term.clear()
  local footer = rows.footer or {}
  for index, entry in ipairs(rows) do
    if index > height - #footer - 1 then break end
    term.setCursorPos(1, index)
    if colour then term.setTextColour(TONES[entry.tone] or colours.white) end
    term.write(entry.text)
  end
  local footerTop = height - #footer + 1
  for index, entry in ipairs(footer) do
    term.setCursorPos(1, footerTop + index - 1)
    if colour then term.setTextColour(TONES[entry.tone] or colours.white) end
    term.write(entry.text)
  end
  if colour then term.setTextColour(colours.white) end
end

-- ------------------------------------------------------------ position entry

--- Read three coordinates from the keyboard. `reader` is injected (production passes `read`).
--- Returns a position, or nil + reason. ALL THREE OR NONE: two axes typed is a typo mid-entry, not
--- a position -- storing it would leave the beacon in a state its own validator rejects.
function Console.readPosition(reader, current)
  local wanted = {}
  for _, axis in ipairs({ "x", "y", "z" }) do
    local existing = current and current[axis]
    local prompt = existing ~= nil
      and ("%s [%d]: "):format(axis:upper(), math.floor(existing))
      or ("%s: "):format(axis:upper())
    if term and term.write then term.write(prompt) end
    local text = tostring(reader() or ""):gsub("%s", "")
    if term and term.write then print() end
    if text == "" and existing ~= nil then
      wanted[axis] = math.floor(existing)
    else
      local number = tonumber(text)
      if number == nil then
        return nil, ("%s is not a number -- nothing was changed"):format(axis:upper())
      end
      wanted[axis] = math.floor(number)
    end
  end
  return wanted
end

--- Read one line as the shared update secret. `reader` is injected (production passes `read`). Blank
--- (after trimming whitespace) returns nil = keep/cancel; the caller never echoes the value back to
--- the screen (only SET/unset is ever shown).
function Console.readToken(reader)
  local text = tostring(reader() or ""):gsub("%s", "")
  if text == "" then return nil end
  return text
end

--- The header shown above the coordinate prompts.
function Console.positionHeader()
  return {
    "Where does THIS computer stand?",
    "",
    "Read the coordinates off F3 and type them in.",
    "A wrong number here poisons every fix the craft",
    "takes, and only the self check will notice.",
    "",
    "Blank keeps the current value.",
    "",
  }
end

return Console
