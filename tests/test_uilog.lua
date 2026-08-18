-- tests/test_uilog.lua
-- Pure UI logger (ui/basalt/uilog.lua): a no-op-when-off, timestamped event log over the shared
-- ring buffer, plus the carbide-URL scraper. No Basalt/peripherals/term.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local UILog = require("ui.basalt.uilog")

t.test("disabled logger is a no-op: event records nothing", function()
  local u = UILog.new(false)
  u:event("INPUT", "click 3,4", 1000)
  u:event("ENGINE", "engSw", 1100)
  t.eq(#u:rows(), 0, "nothing recorded when logging is off")
  t.eq(u.enabled, false)
end)

t.test("enabled logger records timestamped lines, first event seeds t0", function()
  local u = UILog.new(true)
  u:event("INPUT", "click 3,4", 5000)     -- t0 = 5000
  u:event("ENGINE", "engSw ON", 5250)
  local r = u:rows()
  t.eq(#r, 2)
  t.truthy(r[1]:find("+0ms", 1, true), "first line is +0ms")
  t.truthy(r[1]:find("INPUT", 1, true) and r[1]:find("click 3,4", 1, true))
  t.truthy(r[2]:find("+250ms", 1, true), "second line is relative to t0")
  t.truthy(r[2]:find("ENGINE", 1, true))
end)

t.test("event buffers a RAW record; line formatting is deferred to rows()/compose() (off the hot path)", function()
  local u = UILog.new(true)
  u:event("RENDER", "apply 12ms", 5000)
  local raw = u.buf:rows()[1]
  t.eq(type(raw), "table", "buffer holds a raw record, not a pre-formatted string")
  t.eq(raw.kind, "RENDER"); t.eq(raw.msg, "apply 12ms")
  t.truthy(u:rows()[1]:find("+0ms RENDER apply 12ms", 1, true), "rows() formats the record at dump time")
end)

t.test("ring buffer caps the log at its capacity (rolling)", function()
  local u = UILog.new(true, 3)
  for i = 1, 5 do u:event("K", "e" .. i, 1000 + i) end
  local r = u:rows()
  t.eq(#r, 3, "capped at capacity")
  t.truthy(r[3]:find("e5", 1, true), "newest kept")
  t.truthy(r[1]:find("e3", 1, true), "oldest dropped")
end)

t.test("compose wraps the rows with a header for the dump/upload", function()
  local u = UILog.new(true)
  u:event("A", "x", 0)
  local body = u:compose()
  t.truthy(body:find("EH2 UI LOG", 1, true), "has a header")
  t.truthy(body:find("A x", 1, true), "includes the event line")
end)

t.test("scrapeUrl pulls the carbide paste URL out of shell output", function()
  t.eq(UILog.scrapeUrl("Uploaded! https://carbide.example/abc123\n"), "https://carbide.example/abc123")
  t.eq(UILog.scrapeUrl("no url here"), nil)
  t.eq(UILog.scrapeUrl(nil), nil)
end)

return true
