import test from "node:test";
import assert from "node:assert/strict";

import { Mux, MuxError } from "../src/mux.js";

test("MuxError preserves bounded timeout evidence", async () => {
  const timeoutMs = 100;
  const mux = new Mux({
    bin: process.execPath,
    namespace: "",
    defaultTimeoutMs: timeoutMs,
    env: { PARA_MUX_TEST_ENV: "preserved" },
  });

  assert.equal(mux.env.PARA_MUX_TEST_ENV, "preserved");
  await assert.rejects(
    mux.runOrThrow(["-e", "setTimeout(() => {}, 10_000)"], { timeoutMs }),
    (error) => {
      assert.ok(error instanceof MuxError);
      assert.equal(error.code, 1);
      assert.equal(error.timedOut, true);
      assert.equal(error.timeoutMs, timeoutMs);
      assert.deepEqual(error.argv, ["-e", "setTimeout(() => {}, 10_000)"]);
      assert.match(error.message, /mux command timed out after 100 ms/);
      return true;
    }
  );
});

test("MuxError distinguishes an ordinary non-zero exit", async () => {
  const mux = new Mux({ bin: process.execPath, namespace: "" });

  await assert.rejects(
    mux.runOrThrow(["-e", "process.stderr.write('MUX_BOOM'); process.exit(7)"]),
    (error) => {
      assert.ok(error instanceof MuxError);
      assert.equal(error.code, 7);
      assert.equal(error.timedOut, false);
      assert.equal(error.stderr, "MUX_BOOM");
      assert.match(error.message, /mux command failed \(exit 7\)/);
      return true;
    }
  );
});
