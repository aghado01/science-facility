/**
 * Manipulation check for the frame ablation matrix.
 *
 * An experiment that runs sixteen arms and discovers afterwards that three were
 * misconfigured has produced nothing. This renders one chunk per cell and
 * asserts the exact frame line, so every condition is known to emit what it
 * claims BEFORE anything is run against it.
 *
 * The factors nest the way the design does: with MDNAV_FRAME=off there is no
 * frame for the others to shape, so those cells collapse to one.
 */

import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";

import { MdnavEngine } from "../src/engine.ts";
import { registerMdnavTools } from "../src/tools.ts";
import { frameConfig } from "../src/formatting.ts";

let pass = 0,
  fail = 0;
const ok = (name, cond, detail) => {
  if (cond) {
    pass++;
    process.stdout.write(`  ok   ${name}\n`);
  } else {
    fail++;
    process.stdout.write(`  FAIL ${name}${detail ? `\n       ${detail}` : ""}\n`);
  }
};
const eq = (name, a, b) =>
  ok(name, a === b, `expected ${JSON.stringify(b)}\n       got      ${JSON.stringify(a)}`);

const VARS = [
  "MDNAV_FRAME",
  "MDNAV_FRAME_ADDRESS",
  "MDNAV_FRAME_CLOSE",
  "MDNAV_FRAME_SPAN",
  "MDNAV_PREFIX",
];
const clearEnv = () => {
  for (const v of VARS) delete process.env[v];
};

const corpus = join(tmpdir(), "mdnav-matrix-" + process.pid);
const wd = join(tmpdir(), "mdnav-matrix-wd-" + process.pid);
mkdirSync(corpus, { recursive: true });

try {
  writeFileSync(join(corpus, "p.md"), "# Paper\n\n## Abstract\n\nbody one\n", "utf8");

  // One engine, reused: the configuration is read per call, so the same server
  // serves every cell without a restart — which is what lets an experiment
  // switch arms without changing anything an agent can see.
  clearEnv();
  const handlers = new Map();
  const engine = new MdnavEngine();
  registerMdnavTools({ tool: (n, _d, _s, fn) => handlers.set(n, fn) }, engine);
  const call = async (n, a) => (await handlers.get(n)(a)).content[0].text;
  await call("mdnav_discover", { paths: [corpus], workDir: wd });

  // Local coordinate widths belong to the document, so the heading id is read
  // from the outline rather than assumed.
  const ol = await call("mdnav_outline", { docId: "D001", depth: 2 });
  const m = /(H\d+) @ ([0-9a-f]{4}).*Abstract/.exec(ol);
  const HID = m[1],
    digest = m[2];

  // Take the span from a reference render rather than restating it: the test is
  // about which fields appear and how they are spelled, not about arithmetic.
  const refLine = (await call("mdnav_read", { docId: "D001", heading: HID, depth: 2 })).split(
    "\n",
  )[2];
  const SPAN = /\| (\d+ \.\. \d+) \|/.exec(refLine)[1];

  // Rendered lines of one framed read, under a given environment.
  const render = async (env) => {
    clearEnv();
    Object.assign(process.env, env);
    const out = await call("mdnav_read", { docId: "D001", heading: HID, depth: 2 });
    clearEnv();
    return out.split("\n");
  };

  // ────────────────────────────────────────────────── address spelling (4)

  process.stdout.write("\naddress spelling\n");
  const ADDRESS = [
    [
      "full",
      `D001 : ${HID} @ ${digest} | ${SPAN} |`,
      `| D001 : ${HID} @ ${digest}`,
      "address | span | content",
    ],
    [
      "columns",
      `D001 | ${HID} @ ${digest} | ${SPAN} |`,
      `| D001 | ${HID} @ ${digest}`,
      "doc | anchor | span | content",
    ],
    [
      "inner-fused",
      `D001 | ${HID}@${digest} | ${SPAN} |`,
      `| D001 | ${HID}@${digest}`,
      "doc | anchor | span | content",
    ],
    [
      "fused",
      `D001:${HID}@${digest} | ${SPAN} |`,
      `| D001:${HID}@${digest}`,
      "address | span | content",
    ],
  ];
  for (const [mode, frame, close, header] of ADDRESS) {
    const lines = await render({ MDNAV_FRAME_ADDRESS: mode });
    eq(`${mode}: header names the fields emitted`, lines[0], header);
    eq(`${mode}: frame line`, lines[2], frame);
    eq(`${mode}: close line`, lines[lines.length - 1], close);
  }

  // ─────────────────────────────────────────────────────── frame factors

  process.stdout.write("\nclose and span, crossed\n");
  for (const close of ["on", "off"]) {
    for (const span of ["on", "off"]) {
      const lines = await render({ MDNAV_FRAME_CLOSE: close, MDNAV_FRAME_SPAN: span });
      const expectFrame =
        span === "on" ? `D001 : ${HID} @ ${digest} | ${SPAN} |` : `D001 : ${HID} @ ${digest} |`;
      eq(`close=${close} span=${span}: frame line`, lines[2], expectFrame);
      eq(
        `close=${close} span=${span}: header`,
        lines[0],
        span === "on" ? "address | span | content" : "address | content",
      );
      const closed = lines[lines.length - 1] === `| D001 : ${HID} @ ${digest}`;
      eq(
        `close=${close} span=${span}: block ${close === "on" ? "closes" : "does not close"}`,
        closed,
        close === "on",
      );
    }
  }

  // ───────────────────────────────────────────── the baseline cell collapses

  process.stdout.write("\nframe off is one cell, whatever else is set\n");
  const bare = "## Abstract\n\nbody one\n";
  for (const extra of [
    {},
    { MDNAV_FRAME_ADDRESS: "fused" },
    { MDNAV_FRAME_CLOSE: "on" },
    { MDNAV_FRAME_SPAN: "on" },
  ]) {
    clearEnv();
    Object.assign(process.env, { MDNAV_FRAME: "off", ...extra });
    const out = await call("mdnav_read", { docId: "D001", heading: HID, depth: 2 });
    clearEnv();
    eq(`frame=off ${JSON.stringify(extra)} emits bare content`, out, bare);
  }

  // batch_read used to leak the address in an HTML comment when framing was
  // off — an "off" arm that was only off for `read`.
  clearEnv();
  process.env["MDNAV_FRAME"] = "off";
  const batchOff = await call("mdnav_batch_read", {
    requests: [{ docId: "D001", heading: HID, label: "abstract" }],
    depth: 2,
  });
  clearEnv();
  ok(
    "frame=off leaves no provenance in batch_read either",
    !/D001|H0002|mdnav/.test(batchOff),
    batchOff,
  );

  // ──────────────────────────────────────────────────────── other emitters

  process.stdout.write("\nspelling reaches every emitter, not just the frame\n");
  for (const [mode, re] of [
    ["full", /D001 : H\d+ @ [0-9a-f]{4}/],
    ["fused", /D001:H\d+@[0-9a-f]{4}/],
  ]) {
    clearEnv();
    process.env["MDNAV_FRAME_ADDRESS"] = mode;
    const locate = await call("mdnav_locate", { pattern: "body one" });
    const cov = await call("mdnav_coverage", { docIds: ["D001"], depth: 2 });
    clearEnv();
    ok(`${mode}: locate agrees with the frame`, re.test(locate), locate);
    ok(
      `${mode}: coverage agrees with the frame`,
      re.test(cov) || /D001 \|/.test(cov),
      cov.split("\n")[1],
    );
  }

  // ───────────────────────────────────────────────────────── config surface

  process.stdout.write("\nconfiguration\n");
  clearEnv();
  eq(
    "defaults are the shipped format",
    JSON.stringify(frameConfig()),
    JSON.stringify({ frame: true, docColumn: false, spaced: true, close: true, span: true }),
  );
  process.env["MDNAV_FRAME_ADDRESS"] = "nonsense";
  ok("an unrecognised mode falls back rather than silently fusing", frameConfig().spaced === true);
  clearEnv();
  process.env["MDNAV_PREFIX"] = "off";
  ok("the earlier MDNAV_PREFIX spelling still turns framing off", frameConfig().frame === false);
  clearEnv();
} catch (err) {
  process.stdout.write(`\n  SUITE ABORTED: ${err && err.stack ? err.stack : err}\n`);
  fail++;
} finally {
  clearEnv();
  rmSync(corpus, { recursive: true, force: true });
  rmSync(wd, { recursive: true, force: true });
}

process.stdout.write(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail > 0 ? 1 : 0);
