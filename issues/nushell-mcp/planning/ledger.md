# nushell-mcp ledger — completed

Newest first. Point at commits and briefs. Counts are from the commit
they were observed at, not standing claims.

- **2026-08-23 — composition stream cut.** `core/stream.nu`; `process capture`
  `ok` is spawn success (exit independent); string/binary streams sized as
  returned; `rg` rejects binary streams and `path.bytes`/`lines.bytes`. Child
  tests: composition-v1 31/31, par-jobs-v1 29/29, dataspection-v1 13/13,
  xq-v1 8/8, rg-v1 13/13. N18 landed. composition-v1 landed.

- **2026-08-23 — composition ownership cut.** `core/execution.nu`; `par` marks
  workers via `with-env`; `jobs stash --prefix` allocates against existing tags;
  harvest/drain are owner-only. `xq`/`rg`/`read`/`emit` use the three-context
  table (owner stash, in-job inline, foreground worker fail-closed). Child tests:
  composition-v1 27/27, par-jobs-v1 29/29, dataspection-v1 13/13, xq-v1 8/8,
  rg-v1 13/13. N17 landed.

- **2026-08-23 — composition outcome cut.** `core/outcome.nu`; `par` lifts
  returned `{ok: false}` while retaining `value`; `jobs spawn` harvest keeps
  `status: completed` with `ok: false` and a fetchable payload; `jobs cancel`
  missing/non-running is `{ok: false}`. Child tests: composition-v1 20/20,
  par-jobs-v1 29/29, dataspection-v1 13/13, xq-v1 8/8, rg-v1 13/13. N16 landed.

- **2026-08-22 — rg wrapper v1.** `modules/rg/mod.nu` consumes `process capture`,
  injects `--json` once, JSON-event findings / text on the return path, spine
  over cap, `jobs stash` as `rg:<seq>`. In-job never stashes. Child tests
  rg-v1 13/13. Corpus `references/search.md`.

- **2026-08-22 — xq v1 + `process capture`.** `core/capture.nu` unbounded;
  `xq` stamps, caps on stream bytes vs `par cap`, stashes `{stdout, stderr}`.
  In-job never stashes. Child tests xq-v1 8/8. N11 landed.

- **2026-08-22 — N15 jobs/read failure contract** (Sol core review P1/P2).
  Missing/running/failed/cancelled are data; retrieve tags NUON-quoted;
  unknown bytes fail closed; core failure records carry `ok: false`;
  dataspection suite `error make`s on `n_err`. par-jobs-v1 29/29,
  dataspection-v1 13/13.

- **2026-08-22 — N10 `jobs fetch`.** Uncapped retrieve; `jobs read` drops
  `--full`. Decline `retrieve` is `jobs fetch <tag>`. Child tests:
  par-jobs-v1 27/27, dataspection-v1 13/13 (including `--config` smoke).

- **2026-08-22 — layering A landed** (`modules/core/*.nu`, dataspection
  façade). `--config` over-cap `read` declines; overlay has `shape`/`read`
  not `value nuon`. Child tests: dataspection-v1 13/13, par-jobs-v1 27/27.
  N9 landed. Next: N10 (`jobs fetch`) then xq (`core/capture.nu`).

- **2026-08-22 — N9 ruled A** (docs, not code). `layering-v1` frozen:
  `modules/core/*.nu` file units, dataspection façade. B / `dataspection-core`
  / `nushell-mcp-core` rejected. N11 carried into xq-v1 (`process capture`).
  N10 (`jobs fetch`) still open.

- **2026-08-22 — layering-v1 filed (not landed)** `72e0b23`. Spec for
  the census/quarantine cut after `$x | read` broke under `--config`.
  Decision still open (N9). Blocks xq.

- **2026-08-22 — par-jobs amendment** `058f887`. `jobs inspect` fills
  census from `shape`; `jobs read` adopts `par cap` with `--full` as
  retrieve; receipts stamped via `meta stamp`; `par cap` exported.
  Child tests: `par-jobs-v1.nu` 27/27, `dataspection-v1.nu` 13/13
  (`nu -n` only — MCP `--config` path later found `read` broken, N8/N9).

- **2026-08-22 — dataspection v1** `5381bf3` (prep `7462c34`, `4f18d0f`,
  `74328e0`). `shape` / `schema` / `spine` / `preview` / `page` / `meta`
  / in-hand `read`. Child tests 13/13. `hist-v1` remains superseded.

- **2026-08-21 — par / jobs v1** (brief follow-up; later stash/emit
  review fix on the same brief). Data plane + handle plane + budget.
  Archived spec: [par-jobs-v1](../.archive/briefs/par-jobs-v1.md).
