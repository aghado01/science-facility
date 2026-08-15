# reposnapshot MCP surface (vision scoping)

**Status:** vision / scoping · **Filed:** 2026-07-23 · Prereq: mature code-track v3

## Vision (user, 2026-07-23)

A mature reposnapshot v3 becomes an agent-facing tool: sparse, client-specific
**guidance** can encourage an agent to scope a target directory and generate an
RPC-like reposnapshot call that writes a sharded snapshot to a **temp directory** — so
the agent can investigate large bodies of code with lean, pristine context,
iteratively reasoning over selectively-read segments in the course of its work. One
tool for certain situations, but quite powerful for repo-wide analysis. The MCP **codifies the
mechanics** — ensures an agentic model understands how to use snapshots as part of its
own workflow — and provides helpers for **targeted parallel reads**. With the manifest
and self-describing data, a reasoning agent plans, then fetches — without directly
reading the source files.

## Surface sketch

The following are semantic operations, not a commitment to one public MCP tool per
bullet. The eventual public surface should apply the tool-admission rule: expose only
decisions the agent genuinely needs to make, while mount caching, index selection,
packing, scratch placement, and cleanup remain backend concerns.

- **create snapshot** — generate a cheap derived view from a target or multi-root set.
  The ordinary input is a named semantic view profile plus selection, normalization,
  residue, and enrichment overrides. Physical grouping, packing, shard sizing, and
  temporary-path policy retain backend defaults unless an advanced use case actually
  needs them. Return a durable `artifact_ref`, a bounded manifest/catalog orientation,
  and an auto-opened `mount_ref` where the runtime supports mounts; the complete tree
  remains the on-disk entry point and may be returned inline when it fits the response
  budget.
- **open existing snapshot** — validate and bind a previously generated container.
  This is required backend behavior for reuse, restart, and cross-client handoff; it
  deserves a public operation only if agents commonly need to choose an existing pack.
- **query / scan / search** — inspect paths, declared attributes, structural-survey
  entries, keywords, or versioned resemblance projections. Return candidate addresses
  and evidence, not bodies. Search mode is a selector or intent distinction unless a
  genuinely different lifecycle or permission contract justifies another tool.
- **fetch / materialize** — accept a list of shard, row, declared column, or exact byte
  selectors and materialize them in one bounded call. The parallel-read helper is
  therefore backend execution behavior, not necessarily another schema.
- **Decoded spans on return (user, 2026-08-09)** — fetch returns content with the
  content codec already **undone**: no `\n` escapes, no compaction markers, just the
  source text. The server owns the decode, so the reader never meets an encoded
  character and never needs the tree's Compaction key (`shard-format-notes.md` §"The
  Compaction block" — that key exists for the tool-free path, and is per-tree
  precisely because the MCP path does not need it). This is the progressive-
  enhancement pattern working as intended: the tool era makes the cipher key
  *unnecessary* rather than reimplementing it.

  Two riders. **The MCP is the only real decoder in the system** — decode-only, not
  the rehydrate-to-compiler path, which stays theoretical. That turns the codec's
  totality/unambiguity requirement from design discipline into an operational
  dependency the day this ships. And **decoded spans break byte-offset arithmetic**:
  offsets in the tree address the *encoded* artifact, so a decoded return must not be
  re-measured against them. Either return offsets alongside the decoded text, or make
  the decode explicit in the response shape — a decision for the fetch contract.
- **residue access** — disclose retained diagnostics, demoted files, or extracted
  material by kind and address when those channels exist. A declared omission is not
  automatically a retained or reconstructible residue.
- **Codified guidance** — keep a small intent router and retrievable recipes for bulk
  orientation, diagnosis, refresh, residue inspection, and the live-read/test escape
  path. Tool descriptions state when an operation is appropriate; client-harness
  adapters may deliver sparse lifecycle-aware reminders, but the MCP server does not
  itself possess standard `PreToolUse` or compaction hooks.

## Snapshot, artifact, and mount lifecycle

Generation is intentionally cheap. A snapshot is frozen for the life of one artifact
generation, but it is not precious: when the live tree or the question changes, create
a new generation rather than silently retargeting the old address space.

The identities must remain distinct:

| Reference | Meaning | Portability |
|---|---|---|
| Source generation | Live roots, revisions, and input guards used to derive the view | Describes mutable inputs |
| `artifact_ref` | Immutable manifest-plus-shards generation with integrity and profile provenance | Durable and shareable |
| `mount_ref` | Validated runtime binding with a parsed catalog and disposable caches | Local and reacquirable |
| `projection_ref` | Structural, lexical, or resemblance index bound to one artifact generation and profile | Disposable and rebuildable |

Create may auto-mount to avoid a second model turn. The portable collaboration object
is still the artifact, not the mount: another process or client opens the same artifact
and receives its own mount. A server restart may invalidate `mount_ref` without
invalidating `artifact_ref`.

The general lifecycle, validation, query, residue, and receipt rules live in the
[`mounted artifact contract`](../../../issues/mcp/mounted-artifact-contract.md). The
tree remains the tool-free catalog; mounting is the MCP backend's runtime binding of
that catalog and its shards, not an operating-system filesystem mount.

## Progressive enhancement — the two-era design (user, 2026-07-23)

The sharded output was designed **tool-free-first**: early models couldn't be counted
on as tool users, so the payload itself had to be maximally palatable, lean, and
legible raw-in-context — that's the origin of the self-documentation, lean rows, and
embedded guidance. The MCP is a query layer *on top*, never a dependency: the artifact
degrades gracefully — fully usable via web-chat upload with zero tools (hence .txt
camouflage), usable with generic read tools (byte-offset seeks), best with the MCP.

Proven in practice: ~2 years of use via the **public snapshot library**
(`C:\Users\azrie\PDenv\UserGithub\project-snapshots`, ~20 projects / 450 files /
18MB) — a git repo as the distribution channel, making the same artifact reachable by
any model with git MCP, web browsing, or filesystem access. Same exact snapshots
consumed by VSCode Copilot, Perplexity/Gemini/Grok/DeepSeek web chat, and Claude Code.
Concrete outcome: ThermoMapper's PH engine assimilated gudhi-devel and ripserer.jl via
snapshot + interactive Opus sessions. So the access modes are three: web-chat upload ·
local filesystem · public-repo fetch — the MCP adds the fourth (and richest).

The end state is a **self-contained database with the bells and whistles any database
avails to its human users** — for agent users:

- manifest = catalog/schema · shards = pages · tree offsets + `.jidx` = indexes ·
  MCP = query engine + client library · embedded instructions = the operator docs
- **Search modalities behind high-level query intents**: keyword, lexical retrieval,
  structural lookup, and fuzzy resemblance over the dataset — tree-node addresses are
  one way for a reasoning agent to find things, not the only way. SimHash and MinHash
  are lexical/set resemblance rather than semantic understanding; any stronger
  semantic model must be named separately.
- **Preview → fetch handoff contract**: preview calls (row content snippets, metadata
  scans) return *exact* addressing information (shard/row/spans) for the follow-up
  fetch — cheap reconnaissance formalized into the plan→act loop.

## Design notes

- Fetch granularity ladder: shard → row → column → byte span.
- The agent's planning substrate is the ~50-line tree manifest, not the codebase.
- Temp-dir output = snapshots are ephemeral per-investigation artifacts by default.
- Self-description makes the MCP thin: header schema = query schema; tree = address
  book. Disposable server-side mount state may cache the parsed catalog and derived
  indexes, but the generated artifact remains authority and must be sufficient to
  reopen after restart.
- RTE-sniffing rationale doesn't apply inside MCP (server returns text directly), but
  the custom view format remains the reader-optimal serving format.
- The manifest must distinguish a configured filter from retained residue and from a
  byte-reconstructible view. The comment sidecar remains forward design until its
  anchors and byte-for-byte rehydration invariant are implemented and tested.
- Commit provenance freezes the source revision, but normalization or stripping can
  change line and byte coordinates. Original-source citations require an explicit
  source map or a guarded source reference; otherwise citations are snapshot-local.
- Session continuity should persist the durable `artifact_ref`, semantic view summary,
  recent selectors, and optional `mount_ref`; restoration must be able to remount. The
  configurable checkpoint/restore protocol belongs to the shared
  [`Session Continuity contract`](../../../issues/mcp/session-continuity-contract.md),
  while native injection remains a client-harness responsibility.

## Work log

- 2026-07-23 — **Validated use case (user observation), donated by the
  codex-scientiae chip** (models-removed trace of opendataloader-pdf + MinerU): a
  two-repo cross-examination the MCP would have served directly — scoped
  `create_snapshot` (selection patterns over the relevant subtrees) → manifest-first
  orientation → targeted address seeks. The chip hand-rolled the equivalent: Sol's
  commit-pinned pointers as manifest substitute, context-mode indexing as the search
  layer, direct reads only for judgment. Requirements donated: (a) **multi-root /
  cross-repo snapshot** as one investigation artifact; (b) **provenance stamping**
  (commit hash) in the manifest so source claims bind to a frozen revision. Snapshot
  byte citations remain stable directly; original `path:line` citations over a
  transformed view additionally require source mapping — verification receipts stop
  drifting and commit alignment no longer has to be inferred manually;
  (c) temp-dir ephemerality fit the per-investigation pattern exactly; (d) ensemble
  currency — the same snapshot could have been handed to other models for parallel
  takes.

- 2026-08-10 — **Mounted lifecycle and session-continuity refinement:** generation is
  a cheap, repeatable bulk-normalization operation; creation may auto-mount, but the
  artifact and mount identities remain separate. Query returns addresses and fetch
  batches materialization. View configuration is semantic by default, physical
  logistics remain backend-owned, residues carry explicit maturity, and compaction
  survival is supplied by a shared continuity contract plus client-specific adapters
  rather than by the reposnapshot MCP pretending to own host hooks.

_(append)_
