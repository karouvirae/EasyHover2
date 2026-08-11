import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "../tools/build.mjs";

function fixture(files) {
  const root = mkdtempSync(join(tmpdir(), "eh2build-"));
  for (const [rel, body] of Object.entries(files)) {
    const abs = join(root, rel);
    mkdirSync(join(abs, ".."), { recursive: true });
    writeFileSync(abs, body);
  }
  return root;
}

test("minifies each app .lua into dist/<same path>, shrinking bytes", () => {
  const root = fixture({ "fcs/a.lua": "local function add(x, y)\n  return x + y\nend\nreturn add\n" });
  const written = build(root);
  assert.deepEqual(written, ["fcs/a.lua"]);
  const out = readFileSync(join(root, "dist/fcs/a.lua"), "utf8");
  assert.ok(out.length < readFileSync(join(root, "fcs/a.lua"), "utf8").length, "minified is smaller");
  assert.ok(/return/.test(out), "still Lua");
});

test("hard-fails on an unparseable file, naming it, and writes no dist for that build", () => {
  const root = fixture({
    "fcs/good.lua": "return 1\n", // processed before ui/bad.lua (fcs precedes ui in MINIFY_DIRS)
    "ui/bad.lua": "local x = = (",
  });
  assert.throws(() => build(root), /ui\/bad\.lua/);
  assert.equal(existsSync(join(root, "dist")), false, "no dist/ at all -- not even the file minified before the failure");
});

test("is deterministic / idempotent (two builds byte-identical)", () => {
  const root = fixture({ "tools/t.lua": "local a=1 local b=2 return a+b\n" });
  build(root);
  const first = readFileSync(join(root, "dist/tools/t.lua"));
  build(root);
  const second = readFileSync(join(root, "dist/tools/t.lua"));
  assert.deepEqual(first, second);
});

test("copies through nothing outside the minify dirs (basalt/manifests untouched)", () => {
  const root = fixture({ "release/basalt-full.lua": "-- big vendor file\n", "fcs/x.lua": "return 1\n" });
  build(root);
  assert.equal(existsSync(join(root, "dist/release/basalt-full.lua")), false);
  assert.equal(existsSync(join(root, "dist/fcs/x.lua")), true);
});
