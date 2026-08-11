# EMC bind full-region modal list picker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unusable inline Basalt `DropDown` in the EMC bind menus with a full-region modal list picker (readable, namespace-stripped tail-first labels; reliable UP/DOWN/wheel scrolling; no mis-hittable scrollbar), adopted by all four picker consumers.

**Architecture:** A new `ui/basalt/listpicker.lua` renders a modal overlay child-frame (high `z`, opaque) over the frame that owns the bind field; it reuses Basalt's `List` element with `showScrollBar=false` and pre-fitted item text so `List`'s own front-truncation never fires. `ui/basalt/picker.lua` is rewritten to render a small **trigger button** (showing the current selection) that opens the overlay on click, keeping the same public `setOptions` shape so the four consumers need almost no change. The overlay is input-driven (repaints on Basalt's native event pump), so it adds zero telemetry-rate paint load and never touches the FCS-safe render-gate.

**Tech Stack:** CC:Tweaked Lua, Basalt 2.0 FULL build (vendored `release/basalt-full.lua`, pinned `f6cde73`), CraftOS-PC headless test harness.

## Global Constraints

- **Basalt: FULL build only** (`release/basalt-full.lua`), never core/plain/dev. Verify every Basalt element/method against the vendored build, not from memory (the `:setChecked` colon-call no-op lesson: use `defineProperty`-generated `setX` colon-setters, not `el:set("x",v)`).
- **ASCII only** in rendered text — CC:Tweaked's font has no `…` glyph; the front-truncation marker is a plain `~`.
- **No change** to bind/save/drain-safety logic: `Uical._pickBind`/`_pickSide`, `mdb.applyBinding`, `config._pickAssign`, `_toOptions`/`_sideOptions`/`pickerOptions`, and every relay re-block stay byte-for-byte as-is. `onPick` still receives the exact stored `value` (peripheral name, page id, side string, or `false` for "(none)").
- **FCS-safe cadence** (`feedback-ui-cadence-rules`): the overlay must not register work on the 0.2 s render-gate; it repaints only on its own input events.
- **Role membership is the require() dependency closure** (`tools/closure.lua`), not a directory walk. `listpicker.lua` enters the `ui` role manifest only once `picker.lua` requires it (Task 3) — that is the one task that must regenerate `dist/` (`node tools/build.mjs`) and both manifests (`bash tools/run_gen.sh`).
- **Green gates before any merge:** `bash tests/run_headless.sh` (source) + `bash tests/run_headless_dist.sh` (minified) + `bash tests/run_suite_e2e.sh` (11-phase installer), manifests **IN SYNC**.
- Commit messages end with the repo's trailer lines (Co-Authored-By + Claude-Session), per existing history.

## File Structure

- **Create** `ui/basalt/listpicker.lua` — pure `M.formatLabel(name,width)` + the overlay controller `M.make(frame)` (`show/hide/visible/pick/scrollBy`). One responsibility: modal list selection.
- **Rewrite** `ui/basalt/picker.lua` — trigger button + delegation to `listpicker`; retains pure `M.indexOf`; new return surface `{ trigger, overlay, setOptions, setEnabled, selectedItem, getValue }`.
- **Modify** `ui/basalt/bitconfig/mdb.lua` — two `slot.picker.dropdown:setEnabled(...)` calls → `slot.picker.setEnabled(...)`. No other consumer needs a source edit (all use `Picker.make(...).setOptions(...)`).
- **Create** `tests/test_listpicker.lua`; **rewrite** `tests/test_picker.lua`; **edit** `tests/test_region_emc.lua`, `tests/test_bitconfig_uical.lua`, `tests/test_page_config.lua`, `tests/test_bitconfig_mdb.lua` for the new query API.
- **Modify** `tests/run_headless.sh` — register `tests.test_listpicker` in the `suites` list.

---

### Task 1: `ListPicker.formatLabel` (pure)

**Files:**
- Create: `ui/basalt/listpicker.lua`
- Create: `tests/test_listpicker.lua`
- Modify: `tests/run_headless.sh` (add `"tests.test_listpicker"` to the `suites` list on line 32)

**Interfaces:**
- Produces: `ListPicker.formatLabel(name, width) -> string`. Strips one leading `namespace:` segment; if still longer than `width`, keeps the tail and prepends a single `~`; never returns longer than `width`. `width` nil/≤0 → return the namespace-stripped string with no ellipsis. Non-string `name` is `tostring`'d.

- [ ] **Step 1: Write the failing test**

Create `tests/test_listpicker.lua`:
```lua
-- tests/test_listpicker.lua
local t = require("tests.framework")
local ListPicker = require("ui.basalt.listpicker")

t.test("formatLabel strips a leading namespace segment", function()
  t.eq(ListPicker.formatLabel("create:item_vault_12", 20), "item_vault_12")
  t.eq(ListPicker.formatLabel("minecraft:barrel_3", 20), "barrel_3")
end)

t.test("formatLabel keeps names without a namespace unchanged when they fit", function()
  t.eq(ListPicker.formatLabel("redstone_relay_4", 20), "redstone_relay_4")
  t.eq(ListPicker.formatLabel("top", 10), "top")
  t.eq(ListPicker.formatLabel("(none)", 10), "(none)")
end)

t.test("formatLabel front-truncates with ~ keeping the unique tail", function()
  t.eq(ListPicker.formatLabel("redstone_relay_4", 13), "~tone_relay_4")
  t.truthy(#ListPicker.formatLabel("redstone_relay_4", 13) <= 13, "never exceeds width")
  t.truthy(#ListPicker.formatLabel("create:item_vault_1234567", 8) <= 8, "never exceeds width (stripped+trunc)")
end)

t.test("formatLabel with no width returns the stripped full string", function()
  t.eq(ListPicker.formatLabel("create:item_vault_12", nil), "item_vault_12")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh` (after Step 3 registers the file it will load; before the module exists it fails to `require`).
Expected: FAIL — `tests.test_listpicker` load failure ("module not found" / `formatLabel` nil).

- [ ] **Step 3: Write minimal implementation**

Create `ui/basalt/listpicker.lua`:
```lua
-- ui/basalt/listpicker.lua
-- A full-region MODAL list picker: choose ONE value from a candidate list on a tiny (~14-col)
-- monitor region where Basalt's inline DropDown is unusable (front-truncated IDs + a 1-column
-- mis-hittable scrollbar). Reuses Basalt's List for scroll/select/offset, but pre-fits each item's
-- text (namespace stripped, front-ellipsized) so List's own truncation never fires, and sets
-- showScrollBar=false so scrolling is exclusively UP/DOWN buttons + the mouse wheel and a row tap
-- only ever SELECTS. Input-driven: repaints on Basalt's native event pump, never on the FCS-safe
-- render-gate (see feedback-ui-cadence-rules). NO peripheral/Basalt access at module LOAD.
local M = {}

-- formatLabel(name, width): strip a single leading "namespace:" (create:/minecraft:/...), then if
-- still wider than `width`, keep the TAIL (the unique index) marked with a leading "~" (ASCII --
-- CC:Tweaked has no ellipsis glyph). Never longer than width. width nil/<=0 -> stripped, no trunc.
function M.formatLabel(name, width)
  local s = tostring(name)
  local colon = s:find(":", 1, true)
  if colon then s = s:sub(colon + 1) end
  if type(width) == "number" and width > 0 and #s > width then
    s = "~" .. s:sub(#s - width + 2)
  end
  return s
end

return M
```

- [ ] **Step 4: Register the new test suite**

In `tests/run_headless.sh`, add `"tests.test_listpicker"` to the `suites` list on line 32 (append after `"tests.test_picker"`).

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS — `OK`, count increased by 4 tests. (Manifest sync guard stays green: `listpicker.lua` is not yet in any role's require-closure, so the manifest is unchanged.)

- [ ] **Step 6: Commit**

```bash
git add ui/basalt/listpicker.lua tests/test_listpicker.lua tests/run_headless.sh
git commit -m "feat(ui): ListPicker.formatLabel — namespace-strip + ~tail-first labels"
```

---

### Task 2: `ListPicker` overlay controller

**Files:**
- Modify: `ui/basalt/listpicker.lua` (add `M.make`)
- Modify: `tests/test_listpicker.lua` (add overlay-controller tests)

**Interfaces:**
- Consumes: `frame` — a Basalt frame (`frame:getSize()`, `frame:addFrame/addList/addButton/addLabel`).
- Produces: `ListPicker.make(frame) -> controller` where
  - `controller.show(opts)` — `opts = { title, options={{text=,value=},...}, current, onPick=function(value,item) }`. Lazily builds the overlay once, repopulates the list (fresh item tables, `text = formatLabel(o.text, listWidth)`, `value` preserved), selects+scrolls to the option whose `value == current`, and makes the overlay visible.
  - `controller.hide()` — hides the overlay (keeps it built for reuse).
  - `controller.visible() -> boolean`.
  - `controller.pick(index)` — the row-tap seam: fires `opts.onPick(options[index].value, options[index])` then hides. Wired to the list's `onSelect`.
  - `controller.scrollBy(delta)` — offset delta (property setter clamps). Wired to UP/DOWN (± one page).
  - `controller.elements` for tests: `{ overlay, list, title, upBtn, downBtn, backBtn }` (nil until first `show`).

- [ ] **Step 1: Write the failing test**

Append to `tests/test_listpicker.lua`:
```lua
local BasaltApp = require("ui.basalt.app")

t.test("make() is inert until show() (no Basalt built at make time)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = ListPicker.make(frame)
  t.eq(ctrl.visible(), false, "not visible before show")
  t.eq(ctrl.elements, nil, "no elements built before first show")
end)

t.test("show() builds the overlay, formats items, selects current, and is visible", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = ListPicker.make(frame)
  local picked
  ctrl.show({
    title = "BIND PUMP",
    options = {
      { text = "(none)", value = false },
      { text = "create:item_vault_7", value = "create:item_vault_7" },
      { text = "minecraft:barrel_3", value = "minecraft:barrel_3" },
    },
    current = "minecraft:barrel_3",
    onPick = function(v) picked = v end,
  })
  t.eq(ctrl.visible(), true, "overlay visible after show")
  t.truthy(ctrl.elements and ctrl.elements.list, "list element built")
  t.eq(ctrl.list:getSelectedItem().value, "minecraft:barrel_3", "current selected in the list")

  ctrl.pick(2)  -- tap the second option (create:item_vault_7)
  t.eq(picked, "create:item_vault_7", "pick(index) fires onPick with the row's value")
  t.eq(ctrl.visible(), false, "overlay hides after a pick")
end)

t.test("scrollBy changes the list offset; hide() hides; reuse keeps one overlay", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = ListPicker.make(frame)
  local opts = { title = "T", options = {}, current = false, onPick = function() end }
  for i = 1, 30 do opts.options[#opts.options + 1] = { text = "vault_" .. i, value = "vault_" .. i } end
  ctrl.show(opts)
  local ov1 = ctrl.elements.overlay
  ctrl.scrollBy(10)
  t.truthy(ctrl.list:getOffset() > 0, "offset advanced by scrollBy")
  ctrl.hide()
  t.eq(ctrl.visible(), false, "hidden")
  ctrl.show(opts)
  t.eq(ctrl.elements.overlay, ov1, "same overlay reused across show/hide (no accumulation)")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "render must not error: " .. tostring(err))
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `ListPicker.make` is nil / method calls error.

- [ ] **Step 3: Write minimal implementation**

Add to `ui/basalt/listpicker.lua`, above `return M`:
```lua
-- Fresh item tables (formatted text + preserved value). Fresh per show() so Basalt's
-- Collection:selectItem never cross-contaminates a shared options table's .selected flags
-- (same hazard the old picker.lua documented).
local function buildItems(options, width)
  local items = {}
  for i, o in ipairs(options or {}) do
    items[i] = { text = M.formatLabel(o.text, width), value = o.value }
  end
  return items
end

-- M.make(frame) -> controller. Builds NO Basalt elements until the first show() (lazy: many
-- pickers on one page must not each stand up a hidden overlay upfront).
function M.make(frame)
  local ctrl = { frame = frame, list = nil, opts = nil, elements = nil }

  local function build()
    local w, h = frame:getSize()
    local overlay = frame:addFrame({ x = 1, y = 1, width = w, height = h })
    overlay:setZ(100)                 -- above the page's own elements -> captures in-bounds clicks
    overlay:setBackground(colors.black)
    overlay:setVisible(false)

    local title = overlay:addLabel({ x = 1, y = 1, width = w, height = 1, autoSize = false, text = "" })
    local listH = math.max(1, h - 2)  -- rows 2..h-1
    local list  = overlay:addList({ x = 1, y = 2, width = w, height = listH })
    list:setShowScrollBar(false)      -- kill the 1-col mis-hittable bar; UP/DOWN + wheel instead

    local third = math.max(1, math.floor(w / 3))
    local upBtn   = overlay:addButton({ x = 1,             y = h, width = third, height = 1, text = "UP" })
    local downBtn = overlay:addButton({ x = 1 + third,     y = h, width = third, height = 1, text = "DOWN" })
    local backBtn = overlay:addButton({ x = 1 + 2 * third, y = h, width = math.max(1, w - 2 * third), height = 1, text = "BACK" })

    list:onSelect(function(_self, index) ctrl.pick(index) end)
    upBtn:onClick(function() ctrl.scrollBy(-listH) end)
    downBtn:onClick(function() ctrl.scrollBy(listH) end)
    backBtn:onClick(function() ctrl.hide() end)

    ctrl.list = list
    ctrl.listWidth = w
    ctrl.elements = { overlay = overlay, list = list, title = title, upBtn = upBtn, downBtn = downBtn, backBtn = backBtn }
  end

  function ctrl.show(opts)
    if not ctrl.elements then build() end
    ctrl.opts = opts
    ctrl.elements.title:setText(M.formatLabel(opts.title or "pick", ctrl.listWidth))
    ctrl.list:setItems(buildItems(opts.options, ctrl.listWidth))
    ctrl.list:clearItemSelection()
    local idx
    for i, o in ipairs(opts.options or {}) do
      if o.value == opts.current then idx = i break end
    end
    if idx then
      ctrl.list:selectItem(idx)
      ctrl.list:scrollToItem(idx)
    else
      ctrl.list:setOffset(0)
    end
    ctrl.elements.overlay:setVisible(true)
  end

  function ctrl.hide()
    if ctrl.elements then ctrl.elements.overlay:setVisible(false) end
  end

  function ctrl.visible()
    return ctrl.elements ~= nil and ctrl.elements.overlay:getVisible() == true
  end

  function ctrl.pick(index)
    local o = ctrl.opts and ctrl.opts.options and ctrl.opts.options[index]
    if o and ctrl.opts.onPick then ctrl.opts.onPick(o.value, o) end
    ctrl.hide()
  end

  function ctrl.scrollBy(delta)
    if ctrl.list then ctrl.list:setOffset((ctrl.list:getOffset() or 0) + delta) end
  end

  return ctrl
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS — `OK`. (If a Basalt accessor name is wrong — e.g. `setShowScrollBar`, `setZ`, `setOffset`, `scrollToItem`, `setItems`, `onSelect` — the CraftOS render/build throws here; fix by confirming the exact name in `release/basalt-full.lua` and its upstream `src/elements/List.lua`.)

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/listpicker.lua tests/test_listpicker.lua
git commit -m "feat(ui): ListPicker modal overlay controller (List, no scrollbar, UP/DOWN)"
```

---

### Task 3: Swap `picker.lua` to trigger+overlay across all consumers

**Files:**
- Modify: `ui/basalt/picker.lua` (full rewrite; keep `M.indexOf`)
- Modify: `ui/basalt/bitconfig/mdb.lua` (two `.dropdown:setEnabled` → `.setEnabled`)
- Modify: `tests/test_picker.lua` (rewrite for the new surface)
- Modify: `tests/test_region_emc.lua`, `tests/test_bitconfig_uical.lua`, `tests/test_page_config.lua`, `tests/test_bitconfig_mdb.lua` (query-API migration)
- Regenerate: `dist/` (`node tools/build.mjs`) and manifests (`bash tools/run_gen.sh`)

**Interfaces:**
- Consumes: `ListPicker.make`, `ListPicker.formatLabel` (Tasks 1–2); the existing `opts` every consumer already passes to `Picker.make` (`x, y, width, height?, options, current, placeholder, onPick`; `dropdownHeight`/`title` optional).
- Produces: `Picker.make(frame, opts) -> { trigger, overlay, setOptions(options,current), setEnabled(enabled), selectedItem()->option|nil, getValue()->value|nil }`. `M.indexOf(options,current)` unchanged. `selectedItem()`/`getValue()` resolve purely from the last `setOptions` via `indexOf` (no overlay needed) — the drop-in replacement for the old `dropdown:getSelectedItem()`.

- [ ] **Step 1: Rewrite `tests/test_picker.lua` (failing against old picker)**

Replace the whole file:
```lua
-- tests/test_picker.lua
local t = require("tests.framework")
local Picker = require("ui.basalt.picker")
local BasaltApp = require("ui.basalt.app")

t.test("indexOf finds the option matching the current value", function()
  local opts = { { text = "A", value = "a" }, { text = "B", value = "b" }, { text = "C", value = "c" } }
  t.eq(Picker.indexOf(opts, "b"), 2)
  t.eq(Picker.indexOf(opts, "a"), 1)
  t.eq(Picker.indexOf(opts, "zzz"), nil, "no match -> nil")
  t.eq(Picker.indexOf({}, "a"), nil, "empty -> nil")
end)

t.test("picker builds a trigger, reflects current, refreshes options, renders", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local picked
  local p = Picker.make(frame, {
    x = 2, y = 2, width = 12,
    options = { { text = "thruster_2", value = "thruster_2" }, { text = "gimbal_0", value = "gimbal_0" } },
    current = "gimbal_0",
    placeholder = "bind...",
    onPick = function(v) picked = v end,
  })
  t.truthy(p.trigger, "returns the trigger button")
  t.eq(p.selectedItem().value, "gimbal_0", "current reflected")
  t.eq(p.getValue(), "gimbal_0", "getValue == current value")

  p.setOptions({ { text = "relay_1", value = "relay_1" } }, "relay_1")
  t.eq(p.selectedItem().value, "relay_1", "options refreshed + new current selected")

  -- Reused options table across setOptions must reflect the new current.
  local shared = { { text = "x", value = "x" }, { text = "y", value = "y" } }
  p.setOptions(shared, "x"); t.eq(p.getValue(), "x")
  p.setOptions(shared, "y"); t.eq(p.getValue(), "y", "reused table -> follows new current")

  -- Opening the overlay and tapping a row fires the picker's own onPick with the exact value.
  p.overlay.show({ options = shared, current = "y", onPick = function(v) picked = v end })
  p.overlay.pick(1)  -- tap "x"
  t.eq(picked, "x", "overlay pick fires onPick with the row value")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("unbound current (no matching option) -> selectedItem nil, getValue nil", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local p = Picker.make(frame, {
    x = 1, y = 1, width = 10,
    options = { { text = "(none)", value = false }, { text = "a", value = "a" } },
    current = nil, placeholder = "(none)", onPick = function() end,
  })
  t.eq(p.selectedItem(), nil, "current nil matches no option -> nil")
  t.eq(p.getValue(), nil)
  p.setOptions({ { text = "(none)", value = false } }, false)
  t.eq(p.getValue(), false, "(none) is value=false, a real match")
end)

t.test("setEnabled toggles the trigger without error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local p = Picker.make(frame, { x = 1, y = 1, width = 8, options = {}, current = false, onPick = function() end })
  local ok = pcall(function() p.setEnabled(false); p.setEnabled(true) end)
  t.truthy(ok, "setEnabled must not error")
end)
```
> Note: the middle test's `p.overlay.show(...)` line re-supplies `onPick` only to keep the assertion self-contained; the trigger's own click path already wires `opts.onPick`. Keep the simpler form if the reviewer prefers: `p.trigger` click cannot be dispatched headlessly by coordinate reliably, so the overlay seam is exercised directly.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — old `picker.lua` has no `trigger`/`selectedItem`/`getValue`/`overlay`.

- [ ] **Step 3: Rewrite `ui/basalt/picker.lua`**

Replace the whole file:
```lua
-- ui/basalt/picker.lua
-- A one-of-N value picker. Renders a small TRIGGER BUTTON showing the current selection; clicking
-- it opens ui/basalt/listpicker.lua's full-region modal list (readable namespace-stripped tail-first
-- labels, UP/DOWN + wheel, no mis-hittable scrollbar). Replaces the old inline Basalt DropDown,
-- which front-truncated long peripheral IDs to an unreadable shared prefix and hid its scroll on a
-- 1-column bar. Same public setOptions() shape as before, so consumers barely change.
--
-- Returns { trigger, overlay, setOptions(options,current), setEnabled(enabled),
--           selectedItem()->option|nil, getValue()->value|nil }.
-- selectedItem()/getValue() resolve purely from the last setOptions via M.indexOf -- the drop-in
-- replacement for the old dropdown:getSelectedItem(). The pure M.indexOf is unit-tested.
local ListPicker = require("ui.basalt.listpicker")
local M = {}

-- Index of the option whose value == current. nil if none match.
function M.indexOf(options, current)
  for i, o in ipairs(options) do
    if o.value == current then return i end
  end
  return nil
end

-- Make a picker on `frame`. opts = { x, y, width, height=1, options, current, placeholder,
-- title, onPick=function(value,item) }. dropdownHeight (legacy) is accepted and ignored.
function M.make(frame, opts)
  local placeholder = opts.placeholder or "pick..."
  local btnW = opts.width or 10
  local state = { options = opts.options or {}, current = opts.current }
  local overlay = ListPicker.make(frame)

  local trigger = frame:addButton({
    x = opts.x, y = opts.y, width = btnW, height = opts.height or 1, text = "",
  })

  local function currentText()
    local idx = M.indexOf(state.options, state.current)
    local text = idx and state.options[idx].text or placeholder
    return ListPicker.formatLabel(text, btnW)
  end

  local function setOptions(options, current)
    state.options = options or {}
    state.current = current
    trigger:setText(currentText())
  end

  trigger:onClick(function()
    overlay.show({
      title = opts.title or placeholder,
      options = state.options,
      current = state.current,
      onPick = function(value, item)
        if opts.onPick then opts.onPick(value, item) end
      end,
    })
  end)

  local function setEnabled(enabled)
    trigger:setEnabled(enabled and true or false)
  end

  local function selectedItem()
    local idx = M.indexOf(state.options, state.current)
    return idx and state.options[idx] or nil
  end

  local function getValue()
    local it = selectedItem()
    if it then return it.value end
    return nil
  end

  setOptions(state.options, state.current)

  return {
    trigger = trigger,
    overlay = overlay,
    setOptions = setOptions,
    setEnabled = setEnabled,
    selectedItem = selectedItem,
    getValue = getValue,
  }
end

return M
```

- [ ] **Step 4: Update `ui/basalt/bitconfig/mdb.lua`**

Change the two enable/disable calls (currently ~lines 218 and 221):
- `slot.picker.dropdown:setEnabled(true)` → `slot.picker.setEnabled(true)`
- `slot.picker.dropdown:setEnabled(false)` → `slot.picker.setEnabled(false)`

Leave `slot.picker.setOptions(...)` calls unchanged.

- [ ] **Step 5: Migrate the four consumer test files (mechanical)**

Apply this rule across `tests/test_region_emc.lua`, `tests/test_bitconfig_uical.lua`, `tests/test_page_config.lua`, `tests/test_bitconfig_mdb.lua`:
- `<X>.dropdown:getSelectedItem()`  → `<X>.selectedItem()`  (so `...:getSelectedItem().value` → `...selectedItem().value`; `... == nil` checks stay valid).
- `<X>.dropdown ~= nil` / `<X>.dropdown` truthy assertions → `<X>.trigger ~= nil` / `<X>.trigger` (update the message text from "dropdown" to "trigger").
- `<X>.picker.dropdown` (mdb row probe, ~line 209) → `<X>.picker.trigger`.

Known occurrences to fix (verify by grep, don't rely on line numbers):
- `tests/test_region_emc.lua`: `sidePicker.dropdown` truthy (~302); `sidePicker/pumpPicker/tankPicker/relayPicker.dropdown:getSelectedItem().value` (~307-310); `pumpPicker/relayPicker.dropdown:getSelectedItem()` nil checks (~338-339); `sidePicker.dropdown:getSelectedItem().value` (~341).
- `tests/test_bitconfig_uical.lua`: `relay/pump/tank/sidePicker.dropdown:getSelectedItem().value` (~587-590); `relayPicker.dropdown:getSelectedItem()` (~608).
- `tests/test_page_config.lua`: `monPickers.monitor_0/1.dropdown:getSelectedItem()...` (~132-133, 170, 174).
- `tests/test_bitconfig_mdb.lua`: `rowSlots[1].picker.dropdown ~= nil` (~209) → `.picker.trigger ~= nil`.

Then confirm none remain:
```bash
grep -rn "\.dropdown" tests/*.lua   # expected: no matches (outside tests/.craftos generated copies)
```

- [ ] **Step 6: Regenerate dist + manifests (picker now requires listpicker → closure changed)**

```bash
node tools/build.mjs        # minify ui/*.lua incl. new listpicker.lua + rewritten picker.lua into dist/
bash tools/run_gen.sh       # regenerate manifest.lua (min) + manifest-dev.lua (dev)
bash tools/run_gen.sh --check   # expect: in sync
```
Expected: `dist/ui/basalt/listpicker.lua` created, `dist/ui/basalt/picker.lua` updated; both manifests now list `ui/basalt/listpicker.lua` in the `ui` role; `--check` passes.

- [ ] **Step 7: Run the source + minified suites**

Run: `bash tests/run_headless.sh` then `bash tests/run_headless_dist.sh`
Expected: both PASS (`OK`), manifest sync guard green. All picker consumers (`region_emc`, `uical`, `page_config`, `mdb`) green on the new query API; MDB↔binddevices byte-parity test still green (bind/save path untouched).

- [ ] **Step 8: Run the e2e installer gate**

Run: `bash tests/run_suite_e2e.sh`
Expected: 11 phases PASS (real install of the ui role now ships `listpicker.lua`).

- [ ] **Step 9: Commit**

```bash
git add ui/basalt/picker.lua ui/basalt/bitconfig/mdb.lua tests/test_picker.lua \
        tests/test_region_emc.lua tests/test_bitconfig_uical.lua tests/test_page_config.lua \
        tests/test_bitconfig_mdb.lua dist/ manifest.lua manifest-dev.lua
git commit -m "feat(ui): swap EMC bind pickers to full-region ListPicker overlay

Trigger button + modal list overlay replaces the inline DropDown in all four
consumers (region EMC config, UI CAL, MDB, terminal config). New query API
selectedItem()/getValue()/trigger/setEnabled; bind/save/drain-safety untouched.
Regenerated dist + both manifests (listpicker enters ui role closure)."
```

---

## Self-Review

**1. Spec coverage**
- Problem 1 (unreadable truncation) → `formatLabel` (Task 1) + `showScrollBar=false` full-width list (Task 2). ✓
- Problem 2 (mis-hittable scrollbar) → `showScrollBar=false` + UP/DOWN + wheel (Task 2). ✓
- New `ui/basalt/listpicker.lua` with `formatLabel` + `open`/controller → Tasks 1–2. ✓
- Rewrite `picker.lua` same public shape → Task 3. ✓
- All four consumers adopt it; only mdb needs a source edit → Task 3. ✓
- No bind/save/drain-safety change → asserted by unchanged `_pickBind`/`applyBinding` + MDB parity test (Task 3 Step 7). ✓
- FCS-safe cadence (overlay off the render-gate) → design honored (input-driven overlay; no `startScheduled`/`extraDirty` wiring added). ✓
- `~` ASCII marker, region-scoped overlay → `formatLabel` marker (Task 1); overlay parents on the trigger's frame = the EMC region (Task 2/3, no whole-monitor coverage). ✓
- Manifest IN SYNC + dist + e2e → Task 3 Steps 6–8. ✓
- Tests: pure `formatLabel`+`indexOf`, construction/overlay probe, pick/scroll/hide seam → Tasks 1–3. ✓

**2. Placeholder scan** — no TBD/TODO; every code and test step carries real content. ✓

**3. Type consistency** — `controller` surface (`show/hide/visible/pick/scrollBy/elements/list`) is identical across Task 2 definition and Task 3 usage (`p.overlay.show/.pick`). `Picker.make` return surface (`trigger/overlay/setOptions/setEnabled/selectedItem/getValue`) is consistent across the rewrite (Task 3 Step 3) and every test/consumer reference. `formatLabel(name,width)` signature identical in Tasks 1–3. ✓

**Note on headless event routing:** overlay click-capture / z-order correctness (that a covering high-`z` frame consumes in-bounds clicks and the FCS region below still receives its own) is Basalt-runtime behavior not reliably exercised headlessly — consistent with the project's standing "Basalt rendering/event-loop verified in-game, logic unit-tested" convention. The pilot's in-game smoke (open each bind field, scroll, pick a long ID, confirm the binding) is the final gate before merge.
