import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { runCaptured, requestCancel } from "../src/capture.js";
import { deltaOf, waitPattern, waitStable } from "../src/framing.js";
import { Journal } from "../src/journal.js";

async function withTempRoot(fn) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "para-console-test-"));
  try {
    return await fn(root);
  } finally {
    const resolved = path.resolve(root);
    assert.ok(resolved.startsWith(path.resolve(os.tmpdir()), "cleanup remains inside the OS temp root"));
    await fs.rm(resolved, { recursive: true, force: true });
  }
}

test("run preserves exact output, journals a receipt, and survives reopen", async () => {
  await withTempRoot(async (root) => {
    const journal = await new Journal({ root, stream: "agent-regression", inlineLimit: 1024 }).init();
    const expected = "first  \nUnicode: λ 雪 🧪\nlast\t\n";
    let dispatched = false;
    const mux = {
      namespace: "test",
      format: async () => root,
      isDead: async () => false,
      sendLine: async () => {
        dispatched = true;
        await fs.writeFile(journal.turnPath(1, "out"), expected, "utf8");
        await fs.writeFile(
          journal.turnPath(1, "done"),
          JSON.stringify({ code: 0, ok: true, duration_ms: 7, cwd: root }),
          "utf8",
        );
      },
    };

    const receipt = await runCaptured(mux, "agent-regression:0.0", journal, {
      command: "print hostile content",
      shell: "pwsh",
      timeoutMs: 2_000,
      pollMs: 5,
    });
    assert.equal(dispatched, true);
    assert.equal(receipt.complete, true);
    assert.equal(receipt.code, 0);
    assert.equal(receipt.inline, expected);
    assert.equal(receipt.bytes, Buffer.byteLength(expected));

    const { turns, receipt: summaryReceipt } = await journal.summary();
    assert.equal(turns.length, 1);
    assert.equal(turns[0].outcome, "completed");
    const body = await journal.body(1, { limitLines: 20 });
    assert.equal(body.text, expected.replace(/\r?\n$/, ""));

    const cancel = await requestCancel(journal, 1, "regression probe");
    assert.equal(cancel.cooperative, true);
    const cancelEnvelope = JSON.parse(await fs.readFile(journal.turnPath(1, "cancel"), "utf8"));
    assert.equal(cancelEnvelope.reason, "regression probe");

    const reopened = await new Journal({ root, stream: "agent-regression" }).init();
    const next = await reopened.openTurn({ cmd: "next", cwd: root, shell: "pwsh" });
    assert.equal(next.turn, 2);
    assert.equal(next.seq, summaryReceipt.cursor.next);
  });
});

test("read delta distinguishes append, sliding windows, and redraws", () => {
  assert.deepEqual(deltaOf(undefined, "a\nb\n"), { delta: "a\nb", isFirstRead: true });
  assert.deepEqual(deltaOf("a\nb", "a\nb\nc\n"), { delta: "\nc", isFirstRead: false });

  const previous = Array.from({ length: 30 }, (_, i) => `row-${i}`).join("\n");
  const current = Array.from({ length: 30 }, (_, i) => `row-${i + 10}`).join("\n");
  const sliding = deltaOf(previous, current);
  assert.equal(sliding.rewritten, undefined);
  assert.match(sliding.delta, /row-30/);

  const redraw = deltaOf("alpha\nbeta", "menu redrawn elsewhere");
  assert.equal(redraw.rewritten, true);
});

test("wait pattern is evidence-based and cancelled stable waits never send input", async () => {
  const screens = ["booting", "ready xid-42"];
  const mux = {
    captures: 0,
    async capture() {
      const value = screens[Math.min(this.captures, screens.length - 1)];
      this.captures += 1;
      return value;
    },
  };
  const matched = await waitPattern(mux, "target", {
    pattern: "xid-(\\d+)",
    intervalMs: 1,
    timeoutMs: 100,
  });
  assert.equal(matched.matched, true);
  assert.deepEqual(matched.groups, ["42"]);

  const controller = new AbortController();
  controller.abort();
  const cancelled = await waitStable(mux, "target", { signal: controller.signal });
  assert.equal(cancelled.cancelled, true);
  assert.match(cancelled.note, /was not touched/);
});
