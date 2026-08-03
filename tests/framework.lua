local M = { _cases = {} }
function M.test(name, fn) M._cases[#M._cases+1] = { name = name, fn = fn } end
function M.eq(a, b, msg)
  if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. " got " .. tostring(a), 2) end
end
function M.near(a, b, tol, msg)
  if math.abs(a - b) > tol then error((msg or "near") .. ": " .. tostring(a) .. " vs " .. tostring(b) .. " tol " .. tostring(tol), 2) end
end
function M.truthy(v, msg) if not v then error((msg or "truthy") .. ": got " .. tostring(v), 2) end end
function M.run()
  local pass, fail, lines = 0, 0, {}
  for _, c in ipairs(M._cases) do
    local ok, err = pcall(c.fn)
    if ok then pass = pass + 1 else fail = fail + 1; lines[#lines+1] = "FAIL " .. c.name .. ": " .. tostring(err) end
  end
  lines[#lines+1] = ("%d passed, %d failed"):format(pass, fail)
  return fail == 0, table.concat(lines, "\n")
end
return M
