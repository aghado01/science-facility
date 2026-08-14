import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

import { AdapterEngine } from "../../para-agent/src/adapters.js";
import { MediatedTurnService } from "../../para-agent/src/mediated-turn.js";
import { Mux, MuxError, resolveNuBin } from "../../para-agent/src/mux.js";
import { ProcessNativeClient } from "../../para-agent/src/native-client.js";
import { RawTraceSink } from "../../para-agent/src/raw-trace.js";
import { TranscriptStore } from "../../para-agent/src/transcript.js";
import { waitPattern } from "../../para-agent/src/framing.js";

const execFileAsync = promisify(execFile);

function liveMuxIdentity() {
  const suffix = `${process.pid.toString(36)}${Date.now().toString(36).slice(-6)}`;
  return {
    namespace: `pl-${suffix}`,
    session: `s-${suffix}`,
  };
}

test("live Windows substrate matches the pinned Nu and psmux contract", async (t) => {
  if (process.platform !== "win32") {
    t.skip("the pinned psmux smoke is Windows-only");
    return;
  }

  const nuBin = resolveNuBin();
  const { stdout: nuVersion } = await execFileAsync(nuBin, ["--version"], { windowsHide: true });
  assert.match(nuVersion, /0\.114\.1/);

  const { namespace, session } = liveMuxIdentity();
  assert.ok(namespace.length <= 20, "the isolated psmux namespace stays short");
  const mux = new Mux({
    namespace,
    defaultTimeoutMs: 10_000,
    env: { PSMUX_NO_WARM: "1" },
  });
  assert.match(await mux.version(), /3\.3\.7/);
  assert.equal(await mux.hasSession(session), false);

  try {
    let handle;
    try {
      handle = await mux.newSession({
        session,
        command: [
          "pwsh",
          "-NoProfile",
          "-NoExit",
          "-Command",
          "Write-Output 'PARA_LIVE_READY'",
        ],
        width: 100,
        height: 24,
      });
    } catch (error) {
      if (error instanceof MuxError) {
        error.message +=
          "\nThis live gate must be allowed to start a detached Windows ConPTY server; " +
          "rerun it outside an agent process sandbox before attributing the failure to psmux.";
      }
      throw error;
    }
    assert.equal(await mux.hasSession(session), true);
    const ready = await waitPattern(mux, handle, {
      pattern: "PARA_LIVE_READY",
      intervalMs: 50,
      timeoutMs: 10_000,
      scrollback: 100,
    });
    assert.equal(ready.matched, true);

    await mux.sendLine(handle, "Write-Output 'PARA_LIVE_ECHO'");
    const echo = await waitPattern(mux, handle, {
      pattern: "PARA_LIVE_ECHO",
      intervalMs: 50,
      timeoutMs: 10_000,
      scrollback: 100,
    });
    assert.equal(echo.matched, true);
  } finally {
    // The namespace and session are unique to this test. Inspect before exact
    // cleanup so a timed-out client cannot leak a server that started late.
    if (await mux.hasSession(session)) {
      await mux.killSession(session);
    }
  }
});

test("live Claude mediation proves stdin, native terminal reply, provenance, and raw digest", async (t) => {
  if (process.platform !== "win32") {
    t.skip("the installed Claude CLI conformance probe is Windows-only");
    return;
  }

  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "para-live-claude-"));
  const handle = `live-claude-${process.pid}`;
  const prompt = "Reply with exactly PARA_MEDIATED_LIVE_OK and do not use tools.";
  const adapterEngine = await new AdapterEngine().init();
  const nativeClient = new ProcessNativeClient({ defaultTimeoutMs: 120_000 });
  let store = null;

  try {
    store = await TranscriptStore.openWritable({ workspaceRoot, sessionId: handle });
    const service = new MediatedTurnService({
      adapterEngine,
      nativeClient,
      storeForHandle: async () => store,
      traceSinkFactory: async ({ profile, adapter, exchangeId }) => new RawTraceSink({
        traceDir: path.dirname(store.traceDir),
        sessionKey: store.sessionKey,
        exchangeId,
        format: profile.native_events.format,
        adapter,
      }),
    });

    const result = await service.delegate({
      handle,
      application: "claude",
      prompt,
      timeoutMs: 120_000,
    });
    assert.equal(result.reply, "PARA_MEDIATED_LIVE_OK");
    assert.equal(result.receipt.status, "completed");
    assert.equal(result.receipt.prompt.sha256, createHash("sha256").update(prompt).digest("hex"));
    assert.equal(result.receipt.application.id, "claude");
    assert.equal(result.receipt.application.version, "2.1.226");
    assert.match(result.receipt.model.id, /^claude-/);
    assert.equal(result.receipt.trace.complete, true);
    assert.deepEqual(result.receipt.delivery_stages, ["rendered", "adapter_emitted"]);

    const exchange = await store.select({ kind: "exchange", exchangeId: result.receipt.exchange_id });
    assert.equal("application_id" in exchange.trace.raw, false, "selected application is not laundered into live trace provenance");
    assert.equal(exchange.records[0].text, prompt);
    assert.equal(exchange.records.filter((record) => record._type === "response" && record.phase === "final").length, 1);
    const rawPath = store.tracePath(result.receipt.exchange_id);
    const raw = await fs.readFile(rawPath);
    assert.equal(createHash("sha256").update(raw).digest("hex"), result.receipt.trace.sha256);
    assert.match(raw.toString("utf8"), /"type":"result"/);
  } finally {
    nativeClient.close();
    await store?.close();
    const resolved = path.resolve(workspaceRoot);
    assert.ok(resolved.startsWith(path.resolve(os.tmpdir()), "cleanup remains inside the OS temp root"));
    await fs.rm(resolved, { recursive: true, force: true });
  }
});
