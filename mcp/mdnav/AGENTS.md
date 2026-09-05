[[brewery]](./brewery) - place for recipes, fetchers, and other things for rehydrating dependencies and functionality from a cold repo clone (`npm run restore`)

[[build]](./build/) - place for all intermediate disposable artifacts

[[deps]](./deps/) - the materialized dependency payload; consumed directly, never edited by hand

[[tests]](./tests/) - `tests/test-manifest.json` lists the suites, `tests/run-all.mjs` runs them (`npm test`); `typecheck.test.ts` is gate 0 and runs first

Planning, design canon, and the decisions register live in [issues/mdnav](../../issues/mdnav/). Read `planning/roadmap.md` and `planning/decisions.md` before design work. `mdnav.mjs` is the legacy oracle and is never edited (D22/D47).
