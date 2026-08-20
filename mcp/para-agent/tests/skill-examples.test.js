import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

import { server } from "../src/index.js";
import { memoryTransportPair } from "./support/memory-transport.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const skillRoot = path.resolve(here, "../skills/primary");
const packageRequire = createRequire(path.join(skillRoot, "../../package.json"));
const Ajv = packageRequire("ajv");
const { Client } = await import(pathToFileURL(packageRequire.resolve("@modelcontextprotocol/sdk/client/index.js")).href);
const expected = new Map([
  ["references/execution.md", ["delegate", "run", "send", "wait", "read"]],
  ["references/scrutiny.md", [
    "scrutinize",
    "scrutinize",
    "scrutinize",
    "quarantine_status",
    "log",
    "find",
    "body",
  ]],
  ["references/recipes.md", ["spawn", "run", "kill", "delegate", "spawn", "send", "wait", "read", "find"]],
  ["references/lifecycle.md", ["spawn", "spawn", "status", "list", "cancel", "kill"]],
]);

function jsonBlocks(markdown) {
  return [...markdown.matchAll(/```json\s*\r?\n([\s\S]*?)\r?\n```/g)].map((match) => JSON.parse(match[1]));
}

test("primary skill examples validate against the live MCP input schemas", async () => {
  const pair = memoryTransportPair();
  await server.connect(pair.server);
  const client = new Client({ name: "para-agent-skill-test", version: "1.0.0" });
  await client.connect(pair.client);

  try {
    const listed = await client.listTools();
    const tools = new Map(listed.tools.map((tool) => [tool.name, tool]));
    const ajv = new Ajv({ strict: true, allErrors: true });

    for (const [relative, toolNames] of expected) {
      const markdown = await fs.readFile(path.join(skillRoot, relative), "utf8");
      const blocks = jsonBlocks(markdown);
      assert.equal(blocks.length, toolNames.length, `${relative} example count drifted`);

      for (let index = 0; index < blocks.length; index++) {
        const toolName = toolNames[index];
        const tool = tools.get(toolName);
        assert.ok(tool, `${relative} names missing MCP tool '${toolName}'`);
        const validate = ajv.compile(tool.inputSchema);
        assert.equal(
          validate(blocks[index]),
          true,
          `${relative} example ${index + 1} is invalid for ${toolName}: ${ajv.errorsText(validate.errors)}`,
        );
      }
    }
  } finally {
    await client.close();
    await pair.server.close();
  }
});

test("primary skill contains none of the retired pseudo-tool fields", async () => {
  const files = ["SKILL.md", ...expected.keys()];
  const combined = (await Promise.all(files.map((file) => fs.readFile(path.join(skillRoot, file), "utf8")))).join("\n");
  for (const retired of ["killSession", "forPattern", "stableMs", "capture({", "startLine"]) {
    assert.equal(combined.includes(retired), false, `retired skill token remains: ${retired}`);
  }
});
