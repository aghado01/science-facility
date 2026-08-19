import test from "node:test";
import assert from "node:assert/strict";

test("runner pass fixture executes an assertion", () => {
  assert.equal(2 + 2, 4);
});
