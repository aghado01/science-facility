import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { TranscriptStore, TranscriptStoreError } from "../../para-agent/src/transcript.js";
import { TEST_ADAPTER, completedCommit } from "./support/fixtures.js";

async function tempWorkspace(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "para-transcript-test-"));
  t.after(async () => {
    await fs.rm(root, { recursive: true, force: true });
  });
  return root;
}

function acceptanceInput(overrides = {}) {
  return {
    prompt: "Give a bounded answer.",
    senderParticipantId: "primary",
    receiverParticipantId: "para",
    conversationKey: "conversation-1",
    adapter: { ...TEST_ADAPTER },
    requestId: "request-1",
    selectedApplicationId: "codex",
    ...overrides,
  };
}

function failedCommit(acceptance, code = "CLIENT_FAILED") {
  return {
    exchange_id: acceptance.exchange_id,
    status: "failed",
    exchange_end: new Date(Date.parse(acceptance.accepted_at) + 1000).toISOString(),
    outcome: {
      code,
      message: "The receiver did not produce a terminal reply.",
      retryable: true,
      native_stop_confirmed: false,
    },
    trace: {
      complete: false,
      omissions: [{ code: "TRACE_UNAVAILABLE", detail: "No validated receiver-native frame was observed." }],
    },
    delivery: { events: [] },
    records: [],
  };
}

function durableCompletedCommit(acceptance, options = {}) {
  const payload = completedCommit(acceptance, options);
  delete payload.delivery.egress;
  return payload;
}

const AMBIGUOUS_COMMIT_REASON = "terminal transcript commit is ambiguous and requires store reconciliation";

test("read-only open of an unknown session is empty and creates nothing", async (t) => {
  const root = await tempWorkspace(t);
  const store = await TranscriptStore.openReadOnly({ workspaceRoot: root, sessionId: "missing" });
  assert.equal(await store.readHeader(), null);
  assert.deepEqual(await store.select({ kind: "summary" }), []);
  await assert.rejects(() => store.acceptExchange(acceptanceInput()), { code: "TRANSCRIPT_READ_ONLY" });
  await store.close();
  await assert.rejects(() => fs.access(path.join(root, ".para-agent")), { code: "ENOENT" });
});

test("contained session keys prevent raw session labels from becoming paths", async (t) => {
  const root = await tempWorkspace(t);
  const store = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "../../escape:0.1" });
  assert.ok(store.filePath.startsWith(path.join(root, ".para-agent", "transcripts") + path.sep));
  assert.doesNotMatch(path.basename(store.filePath), /\.\./);
  assert.equal((await store.readHeader()).session.session_id, "../../escape:0.1");
  await store.close();

  const composed = new TranscriptStore({ workspaceRoot: root, sessionId: "caf\u00e9" });
  const decomposed = new TranscriptStore({ workspaceRoot: root, sessionId: "cafe\u0301" });
  assert.notEqual(composed.sessionKey, decomposed.sessionKey, "distinct exact session IDs must not alias after display normalization");
});

test("acceptance precedes terminal commit and typed selectors preserve exact exchange semantics", async (t) => {
  const root = await tempWorkspace(t);
  const store = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "happy" });
  const acceptance = await store.acceptExchange(acceptanceInput({ idempotencyKey: "idem-happy" }));
  const { exchange, marker } = await store.commitExchange(durableCompletedCommit(acceptance, {
    traceRef: store.traceRelativeRef(acceptance.exchange_id),
  }));

  assert.equal(exchange.exchange_index, 0);
  assert.equal(exchange.records[0]._type, "prompt");
  assert.equal(exchange.records[0].text, acceptance.prompt.text);
  assert.equal(exchange.sender_participant_id, "primary");
  assert.equal(exchange.receiver_participant_id, "para");
  assert.equal(marker.exchange_id, exchange.exchange_id);
  assert.equal(marker.exchange_index, exchange.exchange_index);
  assert.equal(marker.terminal_status, exchange.status);
  assert.ok(Date.parse(marker.terminal_at) >= Date.parse(exchange.exchange_end));
  assert.equal("recovery" in marker, false);
  assert.deepEqual(
    JSON.parse((await fs.readFile(store.walPath, "utf8")).trimEnd().split("\n").at(-1)),
    marker,
    "commit returns the exact synced terminal marker",
  );
  await store.close();

  const reader = await TranscriptStore.openReadOnly({ workspaceRoot: root, sessionId: "happy" });
  const summaries = await reader.select({ kind: "summary" });
  assert.equal(summaries.length, 1);
  assert.equal(summaries[0].duration_ms, 1000);
  assert.equal(summaries[0].model_id, "gpt-test");
  assert.equal((await reader.select({ kind: "exchange", exchangeId: exchange.exchange_id })).exchange_id, exchange.exchange_id);
  assert.equal((await reader.select({ kind: "records", exchangeId: exchange.exchange_id, recordKind: "response" })).length, 1);
  assert.equal((await reader.select({ kind: "step", exchangeId: exchange.exchange_id, step: 0 }))._type, "prompt");
  assert.equal(await reader.select({ kind: "exchange", exchangeId: `${exchange.exchange_id}-suffix` }), null);
  await assert.rejects(() => reader.query({}, "where true"), { code: "TRANSCRIPT_RAW_QUERY_FORBIDDEN" });
  await reader.close();
});

test("idempotency returns the original acceptance and rejects immutable-input conflicts", async (t) => {
  const root = await tempWorkspace(t);
  const store = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "idempotency" });
  const input = acceptanceInput({ idempotencyKey: "same-operation" });
  const first = await store.acceptExchange(input);
  const replay = await store.acceptExchange({ ...input, requestId: "retry-request" });
  assert.equal(replay.exchange_id, first.exchange_id);
  await assert.rejects(
    () => store.acceptExchange({ ...input, prompt: "Different prompt." }),
    { code: "ACCEPTANCE_IDEMPOTENCY_CONFLICT" },
  );
  await store.close();
});

test("schema and semantic failures occur before terminal transcript or marker mutation", async (t) => {
  const root = await tempWorkspace(t);
  const store = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "prewrite-validation" });
  const acceptance = await store.acceptExchange(acceptanceInput());
  const transcriptBefore = await fs.readFile(store.filePath);
  const walBefore = await fs.readFile(store.walPath);
  const invalid = durableCompletedCommit(acceptance, { traceRef: store.traceRelativeRef(acceptance.exchange_id) });
  invalid.records[0].content_sha256 = "0".repeat(64);

  await assert.rejects(() => store.commitExchange(invalid), { code: "EXCHANGE_RESPONSE_DIGEST" });
  assert.deepEqual(await fs.readFile(store.filePath), transcriptBefore);
  assert.deepEqual(await fs.readFile(store.walPath), walBefore);
  await store.close();
});

test("terminal commit retry is idempotent and conflicting terminal content is rejected", async (t) => {
  const root = await tempWorkspace(t);
  const store = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "terminal-idempotency" });
  const acceptance = await store.acceptExchange(acceptanceInput());
  const payload = durableCompletedCommit(acceptance, { traceRef: store.traceRelativeRef(acceptance.exchange_id) });
  const first = await store.commitExchange(payload);
  const replay = await store.commitExchange(payload);
  assert.deepEqual(replay, first);
  assert.equal((await store.select({ kind: "summary" })).length, 1);

  const conflicting = durableCompletedCommit(acceptance, {
    traceRef: store.traceRelativeRef(acceptance.exchange_id),
    reply: "A conflicting reply.",
  });
  await assert.rejects(() => store.commitExchange(conflicting), { code: "EXCHANGE_TERMINAL_CONFLICT" });
  await store.close();
});

test("process-local writer lane assigns unique commit-order indexes under concurrency", async (t) => {
  const root = await tempWorkspace(t);
  const store = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "concurrent" });
  const acceptances = await Promise.all(
    [0, 1, 2].map((index) => store.acceptExchange(acceptanceInput({
      prompt: `Prompt ${index}`,
      requestId: `request-${index}`,
      conversationKey: `conversation-${index}`,
      idempotencyKey: `idem-${index}`,
    }))),
  );
  const committed = await Promise.all(
    [...acceptances].reverse().map((acceptance) => store.commitExchange(durableCompletedCommit(acceptance, {
      traceRef: store.traceRelativeRef(acceptance.exchange_id),
      reply: `Reply ${acceptance.prompt.text}`,
    }))),
  );
  assert.deepEqual(committed.map(({ exchange }) => exchange.exchange_index).sort((a, b) => a - b), [0, 1, 2]);
  assert.equal(store.nextIndex, 3);
  await store.close();

  const reopened = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "concurrent" });
  assert.equal(reopened.nextIndex, 3);
  await reopened.close();
});

test("exclusive writer lease rejects a live second owner", async (t) => {
  const root = await tempWorkspace(t);
  const first = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "leased" });
  await assert.rejects(
    () => TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "leased" }),
    (error) => error instanceof TranscriptStoreError && error.code === "TRANSCRIPT_WRITER_BUSY",
  );
  await first.close();
});

test("stale writer leases are retained as evidence before reacquisition", async (t) => {
  const root = await tempWorkspace(t);
  const unopened = new TranscriptStore({ workspaceRoot: root, sessionId: "stale" });
  await fs.mkdir(unopened.dirPath, { recursive: true });
  await fs.writeFile(unopened.lockPath, `${JSON.stringify({
    record_type: "transcript_writer_lease",
    schema_version: 1,
    transcript_id: unopened.transcriptId,
    writer_id: "dead-writer",
    pid: 0,
    acquired_at: "2026-08-14T12:00:00.000Z",
    fence: "dead-fence",
  })}\n`, "utf8");

  const store = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "stale" });
  const names = await fs.readdir(store.dirPath);
  assert.ok(names.some((name) => name.startsWith(`${store.sessionKey}.writer.lock.stale.`)));
  await store.close();
});

test("restart recovery terminalizes accepted work exactly once", async (t) => {
  const root = await tempWorkspace(t);
  const first = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "recover-acceptance" });
  const acceptance = await first.acceptExchange(acceptanceInput());
  await first.close();

  const recovered = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "recover-acceptance" });
  const exchange = await recovered.select({ kind: "exchange", exchangeId: acceptance.exchange_id });
  assert.equal(exchange.status, "interrupted");
  assert.equal(exchange.outcome.code, "SERVER_RESTART_RECOVERY");
  assert.equal(exchange.trace.complete, false);
  assert.equal(recovered.nextIndex, 1);
  const notices = recovered.getRecoveryNotices();
  assert.deepEqual(notices, [{
    exchange_id: acceptance.exchange_id,
    conversation_key: "conversation-1",
    terminal_status: "interrupted",
    reason: "SERVER_RESTART_RECOVERY: Durably accepted exchange had no terminal commit when the writer restarted.",
    observed_at: exchange.exchange_end,
    outcome: {
      code: "SERVER_RESTART_RECOVERY",
      message: "Durably accepted exchange had no terminal commit when the writer restarted.",
      native_stop_confirmed: false,
    },
  }]);
  notices[0].outcome.message = "caller mutation";
  assert.equal(
    recovered.getRecoveryNotices()[0].outcome.message,
    "Durably accepted exchange had no terminal commit when the writer restarted.",
  );
  await recovered.close();

  const again = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "recover-acceptance" });
  assert.equal((await again.select({ kind: "summary" })).length, 1);
  assert.equal(again.nextIndex, 1);
  assert.equal(again.getRecoveryNotices()[0].exchange_id, acceptance.exchange_id);
  await again.close();
});

test("restart recovery repairs a missing terminal marker without duplicating the exchange", async (t) => {
  const root = await tempWorkspace(t);
  const first = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "recover-marker" });
  const acceptance = await first.acceptExchange(acceptanceInput());
  await first.commitExchange(failedCommit(acceptance));
  const walPath = first.walPath;
  await first.close();

  const walLines = (await fs.readFile(walPath, "utf8")).trimEnd().split("\n");
  assert.equal(walLines.length, 2);
  await fs.writeFile(walPath, `${walLines[0]}\n`, "utf8");

  const recovered = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "recover-marker" });
  assert.equal((await recovered.select({ kind: "summary" })).length, 1);
  assert.equal((await fs.readFile(walPath, "utf8")).trimEnd().split("\n").length, 2);
  const repairedMarker = JSON.parse((await fs.readFile(walPath, "utf8")).trimEnd().split("\n").at(-1));
  assert.deepEqual(repairedMarker.recovery, {
    kind: "missing_terminal_marker_repaired",
    observed_at: repairedMarker.terminal_at,
    quarantine_reason: AMBIGUOUS_COMMIT_REASON,
  });
  assert.deepEqual(recovered.getRecoveryNotices(), [{
    exchange_id: acceptance.exchange_id,
    conversation_key: "conversation-1",
    terminal_status: "failed",
    reason: "CLIENT_FAILED: The receiver did not produce a terminal reply.",
    observed_at: new Date(Date.parse(acceptance.accepted_at) + 1000).toISOString(),
    outcome: {
      code: "CLIENT_FAILED",
      message: "The receiver did not produce a terminal reply.",
      native_stop_confirmed: false,
    },
  }]);
  await recovered.close();
});

test("exact operator reconciliation is append-only, idempotent, and survives restart", async (t) => {
  const root = await tempWorkspace(t);
  const first = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "reconcile-exact" });
  const acceptance = await first.acceptExchange(acceptanceInput());
  await first.commitExchange(failedCommit(acceptance));
  await first.close();

  const recovered = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "reconcile-exact" });
  const [notice] = recovered.getRecoveryNotices();
  const request = {
    conversationKey: notice.conversation_key,
    exchangeId: notice.exchange_id,
    expected: { reason: notice.reason, observedAt: notice.observed_at },
    basis: {
      kind: "operator_attested_native_stop",
      evidenceRef: "operator-log://stop-confirmation/42",
    },
  };
  const receipt = await recovered.reconcileQuarantine(request);
  assert.match(receipt.reconciliation_id, /^rid-/);
  assert.equal(receipt.record_type, "conversation_reconciliation");
  assert.equal(receipt.conversation_key, notice.conversation_key);
  assert.equal(receipt.exchange_id, notice.exchange_id);
  assert.deepEqual(receipt.expected, {
    reason: notice.reason,
    observed_at: notice.observed_at,
  });
  assert.deepEqual(receipt.basis, {
    kind: "operator_attested_native_stop",
    evidence_ref: "operator-log://stop-confirmation/42",
  });
  assert.deepEqual(receipt.authority, { kind: "local_operator" });
  assert.ok(receipt.writer.writer_id);
  assert.ok(receipt.writer.fence);
  assert.deepEqual(recovered.getRecoveryNotices(), []);

  const walAfterFirst = await fs.readFile(recovered.walPath, "utf8");
  assert.deepEqual(await recovered.reconcileQuarantine(request), receipt);
  assert.equal(await fs.readFile(recovered.walPath, "utf8"), walAfterFirst);
  await assert.rejects(
    () => recovered.reconcileQuarantine({
      ...request,
      basis: { ...request.basis, evidenceRef: "operator-log://different-evidence" },
    }),
    { code: "RECONCILIATION_CONFLICT" },
  );
  assert.equal(await fs.readFile(recovered.walPath, "utf8"), walAfterFirst);
  await recovered.close();

  const again = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "reconcile-exact" });
  assert.deepEqual(again.getRecoveryNotices(), []);
  const walRows = (await fs.readFile(again.walPath, "utf8"))
    .trimEnd()
    .split("\n")
    .map((line) => JSON.parse(line));
  assert.deepEqual(walRows.map((row) => row.record_type), [
    "exchange_acceptance",
    "exchange_terminal_marker",
    "conversation_reconciliation",
  ]);
  await again.close();
});

test("missing completed marker repair restores an exact durable ambiguity until terminal verification", async (t) => {
  const root = await tempWorkspace(t);
  const first = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "reconcile-terminal" });
  const acceptance = await first.acceptExchange(acceptanceInput());
  await first.commitExchange(durableCompletedCommit(acceptance, {
    traceRef: first.traceRelativeRef(acceptance.exchange_id),
  }));
  const walPath = first.walPath;
  await first.close();

  const walLines = (await fs.readFile(walPath, "utf8")).trimEnd().split("\n");
  assert.equal(walLines.length, 2);
  await fs.writeFile(walPath, `${walLines[0]}\n`, "utf8");

  const repaired = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "reconcile-terminal" });
  const marker = JSON.parse((await fs.readFile(walPath, "utf8")).trimEnd().split("\n").at(-1));
  assert.deepEqual(marker.recovery, {
    kind: "missing_terminal_marker_repaired",
    observed_at: marker.terminal_at,
    quarantine_reason: AMBIGUOUS_COMMIT_REASON,
  });
  const [notice] = repaired.getRecoveryNotices();
  assert.deepEqual(notice, {
    exchange_id: acceptance.exchange_id,
    conversation_key: acceptance.conversation_key,
    terminal_status: "completed",
    reason: AMBIGUOUS_COMMIT_REASON,
    observed_at: marker.recovery.observed_at,
  });
  await repaired.close();

  const store = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "reconcile-terminal" });
  assert.deepEqual(store.getRecoveryNotices(), [notice], "the exact repaired-marker quarantine survives restart");
  const request = {
    conversationKey: notice.conversation_key,
    exchangeId: notice.exchange_id,
    expected: {
      reason: notice.reason,
      observedAt: notice.observed_at,
    },
    basis: {
      kind: "terminal_commit_verified",
      evidenceRef: "operator-log://ambiguous-return/51",
    },
  };

  const receipt = await store.reconcileQuarantine(request);
  assert.equal(receipt.record_type, "conversation_reconciliation");
  assert.equal(receipt.exchange_id, acceptance.exchange_id);
  assert.deepEqual(receipt.expected, {
    reason: AMBIGUOUS_COMMIT_REASON,
    observed_at: marker.recovery.observed_at,
  });
  assert.deepEqual(receipt.basis, {
    kind: "terminal_commit_verified",
    evidence_ref: "operator-log://ambiguous-return/51",
  });
  assert.deepEqual(store.getRecoveryNotices(), [], "exact terminal verification suppresses the durable repaired-marker quarantine");
  await store.close();

  const reopened = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "reconcile-terminal" });
  assert.deepEqual(reopened.getRecoveryNotices(), []);
  assert.deepEqual(await reopened.reconcileQuarantine(request), receipt);
  assert.equal(
    (await fs.readFile(reopened.walPath, "utf8")).trimEnd().split("\n").filter(
      (line) => JSON.parse(line).record_type === "conversation_reconciliation",
    ).length,
    1,
  );
  await reopened.close();
});

test("terminal-commit verification rejects invented tuples, wrong evidence, lanes, and unconfirmed stop", async (t) => {
  const root = await tempWorkspace(t);
  const store = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "reconcile-terminal-refusals" });
  const acceptance = await store.acceptExchange(acceptanceInput());
  await store.commitExchange(durableCompletedCommit(acceptance, {
    traceRef: store.traceRelativeRef(acceptance.exchange_id),
  }));
  let walRows = (await fs.readFile(store.walPath, "utf8")).trimEnd().split("\n").map((line) => JSON.parse(line));
  const marker = walRows.at(-1);
  const exact = {
    conversationKey: acceptance.conversation_key,
    exchangeId: acceptance.exchange_id,
    expected: {
      reason: AMBIGUOUS_COMMIT_REASON,
      observedAt: marker.terminal_at,
    },
    basis: {
      kind: "terminal_commit_verified",
      evidenceRef: "operator-log://ambiguous-return/52",
    },
  };
  const walBefore = await fs.readFile(store.walPath);

  await assert.rejects(
    () => store.reconcileQuarantine({
      ...exact,
      expected: { ...exact.expected, reason: "native stop is unconfirmed" },
    }),
    { code: "RECONCILIATION_REASON_MISMATCH" },
  );
  await assert.rejects(
    () => store.reconcileQuarantine({
      ...exact,
      expected: {
        ...exact.expected,
        observedAt: new Date(Date.parse(marker.terminal_at) - 1).toISOString(),
      },
    }),
    { code: "RECONCILIATION_OBSERVATION_PRETERMINAL" },
  );
  await assert.rejects(
    () => store.reconcileQuarantine({
      ...exact,
      conversationKey: "different-conversation",
    }),
    { code: "RECONCILIATION_STALE_TUPLE" },
  );
  await assert.rejects(
    () => store.reconcileQuarantine(exact),
    { code: "RECONCILIATION_STALE_TUPLE" },
    "a normal successful marker does not prove that an ambiguous-commit quarantine existed",
  );
  assert.deepEqual(await fs.readFile(store.walPath), walBefore);

  const unconfirmed = await store.acceptExchange(acceptanceInput({
    conversationKey: "conversation-unconfirmed",
    requestId: "request-unconfirmed",
  }));
  await store.commitExchange(failedCommit(unconfirmed));
  walRows = (await fs.readFile(store.walPath, "utf8")).trimEnd().split("\n").map((line) => JSON.parse(line));
  const unconfirmedMarker = walRows.at(-1);
  const walBeforeUnsafe = await fs.readFile(store.walPath);
  await assert.rejects(
    () => store.reconcileQuarantine({
      conversationKey: unconfirmed.conversation_key,
      exchangeId: unconfirmed.exchange_id,
      expected: {
        reason: AMBIGUOUS_COMMIT_REASON,
        observedAt: unconfirmedMarker.terminal_at,
      },
      basis: {
        kind: "terminal_commit_verified",
        evidenceRef: "operator-log://unsafe-terminal-basis/53",
      },
    }),
    { code: "RECONCILIATION_BASIS_UNSAFE" },
  );
  assert.deepEqual(await fs.readFile(store.walPath), walBeforeUnsafe);
  await store.close();
});

test("reconciliation fails closed for stale tuples, missing evidence, and unsafe terminal basis", async (t) => {
  const root = await tempWorkspace(t);
  const first = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "reconcile-refusals" });
  const acceptance = await first.acceptExchange(acceptanceInput());
  await first.commitExchange(failedCommit(acceptance));
  await first.close();

  const recovered = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "reconcile-refusals" });
  const [notice] = recovered.getRecoveryNotices();
  const exact = {
    conversationKey: notice.conversation_key,
    exchangeId: notice.exchange_id,
    expected: { reason: notice.reason, observedAt: notice.observed_at },
    basis: {
      kind: "operator_attested_native_stop",
      evidenceRef: "operator-log://stop-confirmation/43",
    },
  };
  const walBefore = await fs.readFile(recovered.walPath);

  await assert.rejects(
    () => recovered.reconcileQuarantine({
      ...exact,
      conversationKey: "different-conversation",
    }),
    { code: "RECONCILIATION_STALE_TUPLE" },
  );
  await assert.rejects(
    () => recovered.reconcileQuarantine({
      ...exact,
      exchangeId: `${notice.exchange_id}-wrong`,
    }),
    { code: "RECONCILIATION_STALE_TUPLE" },
  );
  await assert.rejects(
    () => recovered.reconcileQuarantine({
      ...exact,
      expected: { ...exact.expected, reason: `${notice.reason} changed` },
    }),
    { code: "RECONCILIATION_STALE_TUPLE" },
  );
  await assert.rejects(
    () => recovered.reconcileQuarantine({
      ...exact,
      expected: { ...exact.expected, observedAt: "2026-08-14T00:00:00.000Z" },
    }),
    { code: "RECONCILIATION_STALE_TUPLE" },
  );
  await assert.rejects(
    () => recovered.reconcileQuarantine({
      ...exact,
      basis: { ...exact.basis, evidenceRef: "   " },
    }),
    { code: "RECONCILIATION_EVIDENCE_REQUIRED" },
  );
  await assert.rejects(
    () => recovered.reconcileQuarantine({
      ...exact,
      basis: { ...exact.basis, kind: "terminal_commit_verified" },
    }),
    { code: "RECONCILIATION_BASIS_UNSAFE" },
  );
  await assert.rejects(
    () => recovered.reconcileQuarantine({
      ...exact,
      basis: { ...exact.basis, kind: "force" },
    }),
    { code: "RECONCILIATION_BASIS_UNSUPPORTED" },
  );
  assert.deepEqual(await fs.readFile(recovered.walPath), walBefore);
  assert.equal(recovered.getRecoveryNotices().length, 1);
  await recovered.close();
});

test("WAL scan rejects a schema-valid reconciliation that does not exactly match its quarantine", async (t) => {
  const root = await tempWorkspace(t);
  const first = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "reconcile-scan" });
  const acceptance = await first.acceptExchange(acceptanceInput());
  const payload = failedCommit(acceptance);
  await first.commitExchange(payload);
  const notice = {
    exchange_id: acceptance.exchange_id,
    conversation_key: acceptance.conversation_key,
    reason: `${payload.outcome.code}: ${payload.outcome.message}`,
    observed_at: payload.exchange_end,
  };
  const walPath = first.walPath;
  await first.close();
  const marker = JSON.parse((await fs.readFile(walPath, "utf8")).trimEnd().split("\n").at(-1));

  await fs.appendFile(walPath, `${JSON.stringify({
    record_type: "conversation_reconciliation",
    schema_version: 1,
    reconciliation_id: "rid-manual-stale",
    conversation_key: notice.conversation_key,
    exchange_id: notice.exchange_id,
    expected: {
      reason: `${notice.reason} stale`,
      observed_at: notice.observed_at,
    },
    basis: {
      kind: "operator_attested_native_stop",
      evidence_ref: "operator-log://manual-stale",
    },
    reconciled_at: new Date(Date.parse(notice.observed_at) + 2000).toISOString(),
    authority: { kind: "local_operator" },
    writer: marker.writer,
  })}\n`, "utf8");

  await assert.rejects(
    () => TranscriptStore.openReadOnly({ workspaceRoot: root, sessionId: "reconcile-scan" }),
    { code: "RECONCILIATION_STALE_TUPLE" },
  );
});

test("parseable final row without LF is reframed before append", async (t) => {
  const root = await tempWorkspace(t);
  const first = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "missing-lf" });
  const transcriptPath = first.filePath;
  await first.close();
  const headerText = (await fs.readFile(transcriptPath, "utf8")).trimEnd();
  await fs.writeFile(transcriptPath, headerText, "utf8");

  const reopened = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "missing-lf" });
  const acceptance = await reopened.acceptExchange(acceptanceInput());
  await reopened.commitExchange(failedCommit(acceptance));
  await reopened.close();
  const rows = (await fs.readFile(transcriptPath, "utf8")).trimEnd().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(rows.map((row) => row.record_type), ["transcript_header", "transcript_exchange"]);
});

test("torn final JSON and malformed interior rows fail closed without transcript mutation", async (t) => {
  const root = await tempWorkspace(t);
  const initial = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "corrupt" });
  const transcriptPath = initial.filePath;
  await initial.close();
  await fs.appendFile(transcriptPath, "{\"record_type\":", "utf8");
  const tornBytes = await fs.readFile(transcriptPath);

  await assert.rejects(
    () => TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "corrupt" }),
    { code: "TRANSCRIPT_TORN_TAIL" },
  );
  assert.deepEqual(await fs.readFile(transcriptPath), tornBytes);

  const other = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "malformed" });
  const malformedPath = other.filePath;
  await other.close();
  await fs.appendFile(malformedPath, "not-json\n{}\n", "utf8");
  await assert.rejects(
    () => TranscriptStore.openWritable({ workspaceRoot: root, sessionId: "malformed" }),
    { code: "TRANSCRIPT_MALFORMED_ROW" },
  );
});
