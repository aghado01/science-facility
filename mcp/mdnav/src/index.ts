#!/usr/bin/env node
/**
 * mdnav — structure-aware navigation and byte-span addressability MCP server.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { MdnavEngine } from "./engine.ts";
import { registerMdnavTools } from "./tools.ts";

const server = new McpServer({
  name: "mdnav",
  version: "0.3.0",
});

const engine = new MdnavEngine();
registerMdnavTools(server, engine);

const transport = new StdioServerTransport();

process.on("SIGINT", async () => {
  await server.close();
  process.exit(0);
});

process.on("SIGTERM", async () => {
  await server.close();
  process.exit(0);
});

await server.connect(transport);
