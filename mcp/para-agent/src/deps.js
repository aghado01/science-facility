/**
 * Centralized dependency loader for third-party Node packages.
 *
 * Resolves packages directly from deps/node_modules using createRequire,
 * allowing para-agent to run without requiring a root node_modules directory
 * or directory junction.
 */

import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const require = createRequire(new URL("../deps/node_modules/index.js", import.meta.url));

// CommonJS modules
export const z = require("zod").z;
export const Ajv2020 = require("ajv/dist/2020.js");
export const addFormats = require("ajv-formats");

// ES Modules / MCP SDK
const mcpServerUrl = pathToFileURL(require.resolve("@modelcontextprotocol/sdk/server/mcp.js")).href;
const mcpStdioUrl = pathToFileURL(require.resolve("@modelcontextprotocol/sdk/server/stdio.js")).href;

const mcpServerModule = await import(mcpServerUrl);
const mcpStdioModule = await import(mcpStdioUrl);

export const { McpServer } = mcpServerModule;
export const { StdioServerTransport } = mcpStdioModule;
