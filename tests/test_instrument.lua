local t = require("tests.framework")
local I = require("fcs.bringup.instrument")
local frame = require("fcs.frame")

-- CSV split that preserves EMPTY cells (unlike gmatch("[^,]+"), needed to index a row
-- that may legitimately contain "" for a missing string column like `master`).
local function splitCSV(row)
  local cells, start = {}, 1
  while true do
    local commaPos = row:find(",", start, true)
    if commaPos then
      cells[#cells+1] = row:sub(start, commaPos - 1)
      start = commaPos + 1
    else
      cells[#cells+1] = row:sub(start)
      break
    end
  end
  return cells
end

local HEADER_COLS = {}
for c in I.header():gmatch("[^,]+") do HEADER_COLS[#HEADER_COLS+1] = c end
local function idxOf(name)
  for i, c in ipairs(HEADER_COLS) do if c == name then return i end end
  error("no such column: " .. name)
end

t.test("header and formatRow agree on column count", function()
  local ncols = select(2, I.header():gsub(",", ",")) + 1
  local row = I.formatRow({ t=0, dt=0.1, phase="CLIMB", mode="NORMAL", onGround=false, duties={} })
  local nrow = select(2, row:gsub(",", ",")) + 1
  t.eq(nrow, ncols)
end)
t.test("capture snapshots the live duties table so deferred formatRow is immune to later mutation", function()
  -- The control loop reuses/overwrites its duties table each cycle. To move formatRow OFF the hot
  -- path we buffer the raw sample and format at dump time -- which is only safe if the shared duties
  -- reference is snapshotted at capture. This is the correctness guard for that deferral.
  local live = { FL = 0.1, FR = 0.2, RL = 0.3, RR = 0.4 }
  local sample = { t = 1, dt = 0.1, phase = "ENGAGED", mode = "NORMAL", pitch = 0.05, duties = live }
  local rec = I.capture(sample)
  local atCapture = I.formatRow(rec)
  live.FL = 0.99; live.FR = 0.88   -- next cycle overwrites the live duties in place
  t.eq(I.formatRow(rec), atCapture, "captured record's formatRow is unaffected by later duties mutation")
  t.truthy(atCapture:find("0.1000", 1, true), "the FL=0.1 snapshot is preserved for the deferred format")
end)

t.test("Summary computes bob amplitude from HOLD samples", function()
  local s = I.Summary.new()
  s:add({ t=0,   dt=0.1, phase="HOLD", alt=5.0, sp_alt=5, heading=0 })
  s:add({ t=0.1, dt=0.1, phase="HOLD", alt=5.3, sp_alt=5, heading=0 })
  s:add({ t=0.2, dt=0.1, phase="HOLD", alt=4.8, sp_alt=5, heading=0 })
  t.near(s:finalize().bobAmplitude, 0.5, 1e-9)
end)
t.test("Summary tracks per-phase alt error and average Hz", function()
  local s = I.Summary.new()
  s:add({ t=0,   dt=0.2, phase="CLIMB", alt=1.0, sp_alt=1.5, heading=0 })
  s:add({ t=0.2, dt=0.2, phase="CLIMB", alt=2.0, sp_alt=2.0, heading=0 })
  local m = s:finalize()
  t.near(m.errClimb.mean, 0.25, 1e-9); t.near(m.errClimb.max, 0.5, 1e-9)
  t.near(m.hzAvg, 5, 1e-9)
end)
t.test("Summary flags DAMPED and captures touchdown + drift + heading drift", function()
  local s = I.Summary.new()
  s:add({ t=0,   dt=0.1, phase="DESCEND", alt=1,   sp_alt=1,   vSpeed=-0.5, mode="NORMAL", swayPos=0,   surgePos=0,    heading=0 })
  s:add({ t=0.1, dt=0.1, phase="DESCEND", alt=0.5, sp_alt=0.5, vSpeed=-0.3, mode="DAMPED", swayPos=0.4, surgePos=-0.2, heading=0.1 })
  s:add({ t=0.2, dt=0.1, phase="LANDED",  alt=0,   sp_alt=0,   vSpeed=-0.1, mode="NORMAL", swayPos=0.2, surgePos=0,    heading=0.05 })
  local m = s:finalize()
  t.eq(m.damped, true)
  t.near(m.touchdownV, -0.1, 1e-9)
  t.near(m.swayRange, 0.4, 1e-9)
  t.near(m.surgeRange, 0.2, 1e-9)
  t.near(m.headingDrift, 0.1, 1e-9)
end)
t.test("formatSummary produces readable key: value lines", function()
  local s = I.Summary.new(); s:add({ t=0, dt=0.1, phase="HOLD", alt=5, sp_alt=5, heading=0 })
  local out = I.formatSummary(s:finalize())
  t.truthy(out:find("hold_bob_amplitude_blocks:"))
  t.truthy(out:find("loop_hz:"))
end)

-- ===== Task 4: COLUMN CONTRACT expansion =====

t.test("header() emits the new 39 columns in contract order, between the 23 existing and the duties", function()
  local nDuties = #frame.LIFT + #frame.LATERAL + #frame.MAIN + #frame.FRONTAL
  t.eq(#HEADER_COLS, 23 + 39 + nDuties, "total column count == 23 + 39 + duties")
  t.eq(HEADER_COLS[1], "t"); t.eq(HEADER_COLS[23], "dSurge")   -- existing 23 unchanged/first
  t.eq(idxOf("sp_pitch"), 24); t.eq(idxOf("sp_surge"), 28)
  t.eq(idxOf("err_alt"), 29); t.eq(idxOf("err_hdg"), 32); t.eq(idxOf("err_surge"), 34)
  t.eq(idxOf("P_alt"), 35); t.eq(idxOf("I_alt"), 36); t.eq(idxOf("D_alt"), 37)
  t.eq(idxOf("P_surge"), 50); t.eq(idxOf("D_surge"), 52)
  t.eq(idxOf("sat_heave"), 53); t.eq(idxOf("sat_surge"), 58); t.eq(idxOf("heaveBanded"), 59)
  t.eq(idxOf("ff_pitch"), 60)
  t.eq(idxOf("master"), 61); t.eq(idxOf("noFuel"), 62)
  t.eq(HEADER_COLS[63], frame.LIFT[1], "duty columns immediately follow, unchanged/last")
end)

t.test("formatRow(fullSample) places setpoints/derived-err/PID-split/sat/trim/context in contract cells", function()
  local full = {
    t = 1, dt = 0.05, phase = "HOLD", mode = "NORMAL", onGround = false,
    sp_alt = 5, alt = 4.5, vSpeed = 0.1, pitch = 0.02, roll = -0.01, heading = 10, yawRate = 0.5,
    swayVel = 0, surgeVel = 0, swayPos = 1.0, surgePos = 2.0, heave = 0.3,
    dPitch = 0.1, dRoll = 0.2, dYaw = 0.3, dSway = 0.4, dSurge = 0.5,
    sp_pitch = 0.05, sp_roll = 0.0, sp_hdg = 15, sp_sway = 1.5, sp_surge = 2.5,
    terms = {
      alt   = { err = 0.5,  P = 1.0, I = 0.1,  D = 0.01 },
      pitch = { err = 0.03, P = 0.6, I = 0.02, D = 0.003 },
      roll  = { err = 0.01, P = 0.2, I = 0.01, D = 0.001 },
      yaw   = { err = 5,    P = 0.5, I = 0.05, D = 0.005 },
      sway  = { err = 0.5,  P = 0.4, I = 0.04, D = 0.004 },
      surge = { err = 0.5,  P = 0.3, I = 0.03, D = 0.002 },
    },
    sat = { heave = true, pitch = false, roll = true, yaw = false, sway = false, surge = true },
    heaveBanded = true, ff_pitch = 0.12, master = "CPL", noFuel = false, duties = {},
  }
  local cells = splitCSV(I.formatRow(full))
  t.eq(#cells, #HEADER_COLS, "row cell count matches header cell count")
  local function cell(name) return cells[idxOf(name)] end
  t.eq(cell("sp_pitch"), "0.0500"); t.eq(cell("sp_hdg"), "15.0000")
  t.eq(cell("err_alt"), string.format("%.4f", 5 - 4.5))
  t.eq(cell("err_pitch"), string.format("%.4f", 0.05 - 0.02))
  t.eq(cell("err_roll"), string.format("%.4f", 0.0 - (-0.01)))
  t.eq(cell("err_hdg"), string.format("%.4f", 15 - 10))
  t.eq(cell("err_sway"), string.format("%.4f", 1.5 - 1.0))
  t.eq(cell("err_surge"), string.format("%.4f", 2.5 - 2.0))
  t.eq(cell("P_alt"), "1.0000"); t.eq(cell("I_alt"), "0.1000"); t.eq(cell("D_alt"), "0.0100")
  t.eq(cell("P_yaw"), "0.5000"); t.eq(cell("I_yaw"), "0.0500"); t.eq(cell("D_yaw"), "0.0050")
  t.eq(cell("P_surge"), "0.3000"); t.eq(cell("I_surge"), "0.0300"); t.eq(cell("D_surge"), "0.0020")
  t.eq(cell("sat_heave"), "1"); t.eq(cell("sat_pitch"), "0"); t.eq(cell("sat_roll"), "1")
  t.eq(cell("sat_yaw"), "0"); t.eq(cell("sat_sway"), "0"); t.eq(cell("sat_surge"), "1")
  t.eq(cell("heaveBanded"), "1")
  t.eq(cell("ff_pitch"), "0.1200")
  t.eq(cell("master"), "CPL")
  t.eq(cell("noFuel"), "0")
end)

t.test("formatRow(minimalSample) (hover_test path: no terms/sat/sp_*/ff/master/noFuel) does not error", function()
  local minimal = {
    t = 1, dt = 0.1, phase = "CLIMB", mode = "NORMAL",
    sp_alt = 5, alt = 4, vSpeed = 0.1, pitch = 0.01, roll = 0, heading = 0, yawRate = 0,
    swayVel = 0, surgeVel = 0, swayPos = 0, surgePos = 0, onGround = false, heave = 0.2,
    dPitch = 0.1, dRoll = 0, dYaw = 0, dSway = 0, dSurge = 0, duties = {},
  }
  local ok, row = pcall(I.formatRow, minimal)
  t.truthy(ok, "formatRow must not error on a sample missing terms/sat/sp_*/etc: " .. tostring(row))
  local cells = splitCSV(row)
  t.eq(#cells, #HEADER_COLS)
  local function cell(name) return cells[idxOf(name)] end
  t.eq(cell("sp_pitch"), "0.0000")
  t.eq(cell("err_alt"), string.format("%.4f", 5 - 4))   -- sp_alt/alt ARE present (existing cols)
  t.eq(cell("err_pitch"), string.format("%.4f", 0 - 0.01))
  t.eq(cell("P_alt"), "0.0000"); t.eq(cell("D_surge"), "0.0000")
  t.eq(cell("sat_heave"), "0"); t.eq(cell("sat_surge"), "0")
  t.eq(cell("heaveBanded"), "0")
  t.eq(cell("ff_pitch"), "0.0000")
  t.eq(cell("master"), "")
  t.eq(cell("noFuel"), "0")
end)

t.test("Summary tracks per-axis peak |err| and peak |D|", function()
  local s = I.Summary.new()
  s:add({ t = 0, dt = 0.1, phase = "HOLD", alt = 5, sp_alt = 5.2, pitch = 0.1, sp_pitch = 0.0,
    roll = 0, sp_roll = 0, heading = 0, sp_hdg = 3, swayPos = 0, sp_sway = 0.4, surgePos = 0, sp_surge = -0.6,
    terms = {
      alt = { err = 0, P = 0, I = 0, D = 0.02 }, pitch = { err = 0, P = 0, I = 0, D = -0.5 },
      roll = { err = 0, P = 0, I = 0, D = 0.01 }, yaw = { err = 0, P = 0, I = 0, D = 0.03 },
      sway = { err = 0, P = 0, I = 0, D = 0.04 }, surge = { err = 0, P = 0, I = 0, D = -0.07 },
    } })
  s:add({ t = 0.1, dt = 0.1, phase = "HOLD", alt = 5, sp_alt = 4.9, pitch = 0.1, sp_pitch = 0.2,
    roll = 0, sp_roll = -0.1, heading = 0, sp_hdg = 2, swayPos = 0, sp_sway = -0.1, surgePos = 0, sp_surge = 0.1,
    terms = {
      alt = { err = 0, P = 0, I = 0, D = 0.01 }, pitch = { err = 0, P = 0, I = 0, D = 0.05 },
      roll = { err = 0, P = 0, I = 0, D = 0.2 }, yaw = { err = 0, P = 0, I = 0, D = 0.9 },
      sway = { err = 0, P = 0, I = 0, D = -0.01 }, surge = { err = 0, P = 0, I = 0, D = 0.02 },
    } })
  local m = s:finalize()
  t.near(m.peakErr.alt, 0.2, 1e-9)     -- max(|5.2-5|, |4.9-5|)
  t.near(m.peakErr.pitch, 0.1, 1e-9)   -- max(|0-0.1|, |0.2-0.1|)
  t.near(m.peakErr.yaw, 3, 1e-9)       -- max(|3-0|, |2-0|)
  t.near(m.peakD.pitch, 0.5, 1e-9)
  t.near(m.peakD.yaw, 0.9, 1e-9)
  t.near(m.peakD.surge, 0.07, 1e-9)
  local out = I.formatSummary(m)
  t.truthy(out:find("peak_err"), "formatSummary includes peak_err line")
  t.truthy(out:find("peak_D"), "formatSummary includes peak_D line")
end)

t.test("Summary handles samples with no terms/sp_* (hover_test path) without erroring", function()
  local s = I.Summary.new()
  local ok = pcall(function()
    s:add({ t = 0, dt = 0.1, phase = "HOLD", alt = 5, sp_alt = 5, heading = 0 })
  end)
  t.truthy(ok, "Summary:add must not error on a sample missing terms/sp_pitch/etc")
  local m = s:finalize()
  t.eq(m.peakErr.pitch, 0)
  t.eq(m.peakD.pitch, 0)
end)
