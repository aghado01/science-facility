# reposnapshot MCP surface (vision scoping)

**Status:** vision / scoping · **Filed:** 2026-07-23 · Prereq: mature code-track v3

## Vision (user, 2026-07-23)

A mature reposnapshot v3 becomes an agent-facing tool: context-mode-style **nudges**
encourage an agent to scope a target directory and generate an RPC-like reposnapshot
call that writes a sharded snapshot to a **temp directory** — so the agent can
investigate large bodies of code with lean, pristine context, iteratively reasoning
over selectively-read segments in the course of its work. One tool for certain
situations, but quite powerful for repo-wide analysis. The MCP **codifies the
mechanics** — ensures an agentic model understands how to use snapshots as part of its
own workflow — and provides helpers for **targeted parallel reads**. With the manifest
and self-describing data, a reasoning agent plans, then fetches — without directly
reading the source files.

## Surface sketch

- **create_snapshot(target_dir, knobs…)** — RPC-like generation; full knob surface
  (span/grouping/packing, ignore/selection, strip ops, attributes toggle) as call
  params; output to temp dir; returns the tree manifest (entry point) inline.
- **fetch** — selection by: specific shard file · specific **columns** (driven by the
  header schema — e.g. content only, or path+attributes only) · direct **byte spans**
  (tree offsets). No raw file reads needed.
- **parallel-read helper** — batch multiple targeted spans in one call; matches the
  manifest's "iterate over multiple inference cycles" guidance and modern parallel
  tool-calling.
- **preview / scan utilities (TBD)** — content-block previews; row-level metadata
  scans across many files/rows (attributes: entropy, whitespace ratio, counts) to
  enhance planning and agency before any content fetch.
- **Codified guidance** — the tree's operational/metacognitive instruction block
  elevated into the tool contract (tool descriptions, nudge prompts); first-class
  guidance doctrine extends from payload to protocol.

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
- **Search modalities as tool calls**: keyword and semantic search over the dataset —
  tree-node addresses are one way for a reasoning agent to find things, not the only
  way.
- **Preview → fetch handoff contract**: preview calls (row content snippets, metadata
  scans) return *exact* addressing information (shard/row/spans) for the follow-up
  fetch — cheap reconnaissance formalized into the plan→act loop.

## Design notes

- Fetch granularity ladder: shard → row → column → byte span.
- The agent's planning substrate is the ~50-line tree manifest, not the codebase.
- Temp-dir output = snapshots are ephemeral per-investigation artifacts by default.
- Self-description makes the MCP thin: header schema = query schema; tree = address
  book; no server-side state beyond the generated artifacts.
- RTE-sniffing rationale doesn't apply inside MCP (server returns text directly), but
  the custom view format remains the reader-optimal serving format.
- Precedent for the nudge layer: user's own context-mode(-routing) deployment.

## Work log

_(append)_
