-- EasyHover 2 -- mainThread write-batching probe (standalone, no dependencies).
--
-- QUESTION IT ANSWERS: does dispatching N thruster writes CONCURRENTLY (via the parallel API)
-- cost ~1 server tick, instead of N ticks the way N SEQUENTIAL writes do? Flight #6 showed the
-- control loop collapses to ~3Hz while maneuvering because it writes the lift thrusters one at a
-- time (~50ms each, serialized). CC:Tweaked source says a computer may drain many mainThread
-- tasks per tick (5ms budget; setPower is trivial), so concurrent dispatch SHOULD batch them into
-- one tick. This probe measures that on YOUR server before we rewrite the actuation path.
--
-- SAFE: every call is setPower(0) -- it exercises the real write path but leaves the craft inert
-- (thrusters off). It does NOT fire anything. Fuel state is irrelevant; nothing will move.
--
-- Run on the FCS PC:
--   wget https://raw.githubusercontent.com/maar-10/EasyHover2/worktree-level-actuator/tools/probe_batch.lua
--   probe_batch
-- (or `wget run <url>` to fetch+run once).

local REPS = 5   -- measurements averaged per N (median reported to shrug off tick jitter)

local function findThrusters()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "thruster" then names[#names + 1] = name end
  end
  return names
end

-- Pre-wrap once so wrapping cost is out of the measurement. Wrapped peripherals take NO self: p.setPower(x).
local function wrapAll(names)
  local ps = {}
  for i, name in ipairs(names) do ps[i] = peripheral.wrap(name) end
  return ps
end

local function median(t)
  local c = {}
  for i = 1, #t do c[i] = t[i] end
  table.sort(c)
  return c[math.ceil(#c / 2)]
end

-- One SEQUENTIAL pass: write all N thrusters one after another (what the loop does today).
local function timeSequential(ps, n)
  local t0 = os.epoch("utc")
  for i = 1, n do ps[i].setPower(0) end
  return os.epoch("utc") - t0
end

-- One CONCURRENT pass: dispatch all N writes as parallel coroutines so their mainThread tasks
-- queue together and (hypothesis) drain in a single tick.
local function timeParallel(ps, n)
  local fns = {}
  for i = 1, n do fns[i] = function() ps[i].setPower(0) end end
  local t0 = os.epoch("utc")
  parallel.waitForAll(table.unpack(fns, 1, n))
  return os.epoch("utc") - t0
end

local function measure(ps, n)
  local seq, par = {}, {}
  for _ = 1, REPS do seq[#seq + 1] = timeSequential(ps, n) end
  for _ = 1, REPS do par[#par + 1] = timeParallel(ps, n) end
  return median(seq), median(par)
end

local function main()
  local names = findThrusters()
  if #names == 0 then
    print("No 'thruster' peripherals found. Connect the craft's wired network and retry.")
    return
  end
  local ps = wrapAll(names)
  local total = #names
  print(("Found %d thruster(s). Measuring sequential vs concurrent setPower(0)."):format(total))
  print("(all writes are setPower(0) -- nothing fires)\n")
  print(" N  | sequential | concurrent | seq/write | verdict")
  print("----+------------+------------+-----------+---------------------------")
  local counts, seen = {}, {}
  for _, n in ipairs({ 1, 2, 4, 8, total }) do
    if n >= 1 and n <= total and not seen[n] then seen[n] = true; counts[#counts + 1] = n end
  end
  for _, n in ipairs(counts) do
    local seq, par = measure(ps, n)
    local verdict = ""
    if n > 1 then
      if par <= seq * 0.6 then verdict = "BATCHES (concurrent wins)"
      elseif par >= seq * 0.85 then verdict = "no batching"
      else verdict = "partial" end
    end
    print(("%3d | %7d ms | %7d ms | %6.1f ms | %s"):format(n, seq, par, seq / n, verdict))
  end
  -- leave everything off
  for i = 1, total do ps[i].setPower(0) end
  print("\nInterpretation:")
  print(" - If 'concurrent' stays ~flat (~one tick, ~50-100ms) as N grows while 'sequential'")
  print("   climbs ~50ms per thruster -> batching works -> the parallel-writer fix will hold ~18Hz.")
  print(" - If 'concurrent' tracks 'sequential' (both climb with N) -> no batching -> rethink.")
end

main()
