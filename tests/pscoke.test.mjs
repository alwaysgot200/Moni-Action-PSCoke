import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const source = readFileSync(path.join(here, "..", "ps", "pscoke.jsx"), "utf8");
const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(source, sandbox, { filename: "pscoke.jsx" });

// vm 里创建的对象原型属于另一个 realm，先转成本 realm 的普通对象再比较。
const plain = (value) => JSON.parse(JSON.stringify(value));

test("moniGridCells lays out images left to right with gaps", () => {
  const cells = plain(sandbox.moniGridCells(4, 1000, 600, 2, 20));
  assert.equal(cells.length, 4);
  assert.deepEqual(cells[0], { x: 20, y: 20, w: 470, h: 270 });
  assert.deepEqual(cells[1], { x: 510, y: 20, w: 470, h: 270 });
  assert.deepEqual(cells[3], { x: 510, y: 310, w: 470, h: 270 });
});

test("moniGridCells clamps columns and falls back when margins overflow", () => {
  assert.equal(sandbox.moniGridCells(3, 100, 100, 0, 10).length, 3);
  assert.equal(sandbox.moniGridCells(3, 100, 100, 99, 10)[1].y, 10);

  // 间距大到装不下时退化为 0 间距。
  const cramped = plain(sandbox.moniGridCells(2, 100, 100, 2, 60));
  assert.equal(cramped[0].w, 50);
  assert.equal(cramped[0].h, 100);
});

test("moniCanvasCell keeps a symmetric margin", () => {
  assert.deepEqual(plain(sandbox.moniCanvasCell(1000, 600, 20)), {
    x: 20,
    y: 20,
    w: 960,
    h: 560,
  });
});

test("moniLayerName collapses whitespace and truncates", () => {
  assert.equal(sandbox.moniLayerName("  photo \n 01  ", 40), "photo 01");
  assert.equal(sandbox.moniLayerName("", 10), "Image");
  assert.equal(sandbox.moniLayerName("abcdefghijklmnop", 8).length, 8);
});

test("moniClampInt rounds and clamps", () => {
  assert.equal(sandbox.moniClampInt("3.6", 1, 8), 4);
  assert.equal(sandbox.moniClampInt(0, 1, 8), 1);
  assert.equal(sandbox.moniClampInt(99, 1, 8), 8);
});
