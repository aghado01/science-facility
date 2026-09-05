# mdnav

A single-package Node + TypeScript project laid out like [TeXdig](D:/aipithicus/TeXdig): pnpm with exact pins, `tsconfig.base.json` extended by `tsconfig.json` (src) and `tsconfig.tests.json` (tests + config), vitest, eslint (type-checked), prettier. Source runs directly under Node (no build step; `erasableSyntaxOnly` keeps that true).

- `pnpm install --frozen-lockfile` after a clean clone; `pnpm check` runs typecheck, lint, format:check, vitest, and the legacy suites in that order.
- `src/` is the MCP server; `.mcp.json` at the repo root launches `node ./mcp/mdnav/src/index.ts`.
- `tests/*.test.ts` run under vitest; `tests/typecheck.test.ts` is gate 0. `tests/*.mjs` are the pre-vitest self-reporting suites, run by `pnpm test:legacy`, grandfathered until M0 adapts them (D47, D48).
- `mdnav.mjs` is the legacy CLI and the capability oracle. It is never edited, formatted, or linted (D22/D47).
- `skills/` is served to agents byte-for-byte and is excluded from prettier.

Planning, design canon, and the decisions register live in [issues/mdnav](../../issues/mdnav/). Read `planning/roadmap.md` and `planning/decisions.md` before design work.
