/**
 * Centralized dependency loader for the mdnav MCP server.
 *
 * Runtime dependencies are pinned once in brewery/node/package.json and
 * materialized into deps/node_modules by brewery/node/restore-node.ps1.
 * Nothing here reaches outside the package.
 */

import { createRequire } from "node:module";
import { pathToFileURL, fileURLToPath } from "node:url";
import { resolve, dirname } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const depsRoot = resolve(__dirname, "../deps/node_modules");

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
