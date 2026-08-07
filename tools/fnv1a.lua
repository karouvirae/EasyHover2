-- FNV-1a, 32-bit, lower-case hex, over the string's bytes (caller LF-normalises).
-- Shared by easyhover2_suite.lua (which embeds an identical copy) and tools/gen_manifest.lua.
-- 32-bit multiply split into 16-bit halves: the naive product reaches ~7.2e16, past the 2^53
-- exact-integer limit of a Lua double, and would silently lose precision.
local FNV_PRIME, FNV_OFFSET = 16777619, 2166136261

local function fnv1a(s)
  local h, n, i = FNV_OFFSET, #s, 1
  while i <= n do
    local j = i + 255
    if j > n then j = n end
    local b = { string.byte(s, i, j) }
    for k = 1, #b do
      h = bit32.bxor(h, b[k])
      local lo = h % 65536
      local hi = (h - lo) / 65536
      h = ((hi * FNV_PRIME % 65536) * 65536 + lo * FNV_PRIME) % 4294967296
    end
    i = j + 1
  end
  return ("%08x"):format(h)
end

return fnv1a
