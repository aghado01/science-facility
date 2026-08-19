import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { spawn, spawnSync } from "node:child_process";
import path from "node:path";

const outputRoot = path.resolve(process.argv[2] ?? ".codex/agy-native-stream-capture");
const prompt = "Do not use tools. Reply with exactly the single token PARA_AGY_NATIVE_STREAM_PROBE_20260814.";
const command = "C:\\Users\\azrie\\AppData\\Local\\agy\\bin\\agy.exe";
const args = [
  "--print",
  "--output-format", "stream-json",
  "--mode", "plan",
  "--sandbox",
  "--disable-slash-commands",
  "--print-timeout", "2m",
];

const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const version = spawnSync(command, ["--version"], { encoding: "utf8" });
const launchedAt = new Date().toISOString();
const child = spawn(command, args, { cwd: process.cwd(), stdio: ["pipe", "pipe", "pipe"] });
const stdout = [];
const stderr = [];
child.stdout.on("data", (chunk) => stdout.push(chunk));
child.stderr.on("data", (chunk) => stderr.push(chunk));
child.stdin.end(Buffer.from(prompt, "utf8"));

const result = await new Promise((resolve, reject) => {
  child.on("error", reject);
  child.on("close", (code, signal) => resolve({ code, signal }));
});
const stdoutBytes = Buffer.concat(stdout);
const stderrBytes = Buffer.concat(stderr);
await mkdir(outputRoot, { recursive: true });
await writeFile(path.join(outputRoot, "stdout.raw"), stdoutBytes);
await writeFile(path.join(outputRoot, "stderr.raw"), stderrBytes);
const metadata = {
  schema_version: 1,
  launched_at: launchedAt,
  completed_at: new Date().toISOString(),
  application: "agy",
  version: version.status === 0 ? version.stdout.trim() : null,
  command: [command, ...args],
  cwd: process.cwd(),
  prompt: { bytes: Buffer.byteLength(prompt, "utf8"), sha256: sha256(prompt) },
  process: result,
  stdout: { bytes: stdoutBytes.length, sha256: sha256(stdoutBytes) },
  stderr: { bytes: stderrBytes.length, sha256: sha256(stderrBytes) },
};
await writeFile(path.join(outputRoot, "metadata.json"), `${JSON.stringify(metadata, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify(metadata)}\n`);
process.exitCode = result.code ?? 1;
