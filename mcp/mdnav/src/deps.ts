/**
 * Centralized dependency loader for mdnav MCP server.
 */

import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const depsRoot = resolve(__dirname, "../../para-agent/deps/node_modules");

const req = createRequire(resolve(depsRoot, "index.js"));

// Zod
export const z = req("zod").z;

// MCP SDK
const mcpServerUrl = pathToFileURL(resolve(depsRoot, "@modelcontextprotocol/sdk/dist/esm/server/mcp.js")).href;
const mcpStdioUrl = pathToFileURL(resolve(depsRoot, "@modelcontextprotocol/sdk/dist/esm/server/stdio.js")).href;

const mcpServerMod = await import(mcpServerUrl);
const mcpStdioMod = await import(mcpStdioUrl);

export const { McpServer } = mcpServerMod;
export const { StdioServerTransport } = mcpStdioMod;
