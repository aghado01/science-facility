# issues/mdnav

Design canon, execution briefs, planning ledgers, and evidence for `mcp/mdnav`. This folder is the
merge of the former `issues/mdnav_v1/` and `issues/mdnav_v2/` (2026-09-05, decision D48); the
package itself was consolidated the same day — `mcp/mdnav_v2/` was a dependency scaffold and was
folded into `mcp/mdnav/`.

| Folder | Holds | Start with |
|---|---|---|
| `design/` | canon — the "why" and the shape; amended, never forked | `mdnav_v2_design-brief.md`, then `mdnav_v2_structure-brief.md`; design-stage: `mdnav_v2_modes-brief.md`, `adjutant-brief.md` (D50) |
| `briefs/` | execution-ready phase specs, one per milestone group | `01` → `05` in order |
| `planning/` | the execution queue, the decisions register, the bug inventory, the substrate register (general items harvested from mode design, swept before a mode is built) | `roadmap.md`, `decisions.md`, `bug-inventory.md`, `substrate-register.md` |
| `reports/` | dated reviews and captures — records, not live specs | `m0-legacy-capture-20260817.md` |
| `archaeology/` | the legacy file read as a figure model; raw specimens | `figure-model-survey.md` |
| `discussions/` | design transcripts with other models; historical | read only when a decision row cites one |

Files prefixed `v1-` came from `issues/mdnav_v1/` and concern the **current** MCP server rather
than the v2 engine. Two of them are still open work:

- `reports/v1-codex-workdir-singleton-defect.md` — the server holds one engine; switching artifact
  roots leaks document identities across corpora and most tools ignore their `workDir` argument.
  `discussions/v1-claude-on-codex-workdir-report.md` is the second opinion on it. Both are now
  consolidated, with the latent defects found alongside them, in
  [planning/bug-inventory.md](planning/bug-inventory.md) (probe battery:
  `reports/bug-probes-20260905.mjs`).
- `planning/v1-prefixing-ablation-TODO.md` and `discussions/v1-claude-bishop-corpus-prefix-ablation.md`
  — the context-prefix ablation (named `MDNAV_PREFIX` levels, Bishop as a graded-confusability
  testbed). Overlaps the roadmap's "token-cost measurement battery"; fold it in there when that
  brief is written.
- `archaeology/v1-specimen-perplexity-signed-links.md` — a specimen of presigned object-store links
  in the wild, the case the `signed-url` strip species was built from.

Paths inside dated reports and transcripts are left as written; where they say
`skills/doc-dive/mdnav/` or `mcp/mdnav_v2/`, read `mcp/mdnav/`.
