---
name: project-reposnapshot-contract
description: "reposnapshot's design contract — never-fail ingest of arbitrary (incl. broken) code; language handlers are semantics-preserving configurable transformers, NOT parsers/extractors"
metadata:
  node_type: memory
  type: project
  originSessionId: bb7ca063-0c37-459a-8f94-c9ff47600978
  modified: 2026-07-27T22:55:05.248Z
---

reposnapshot (`D:\aghado01\utils\reposnapshot`, v3 = rs.core.\* modules + processors chain) exists to ingest ANY code — broken included; sharing unparseable code for debugging is a core use case. Ingest must never fail on a parse.

Language handlers (rs-psstrip, rs-csstrip, ...) are NOT about parsing or code analysis. They implement contractual guarantees + a configuration surface for selective stripping (comment classes: block/interior/line/inline/doc), regularization, and canonicalization that respects the language and never breaks the code. AST is used where the host provides it natively (PS `Parser::ParseInput` tokens); regex fallback is gated on specific parse-error IDs. Degradation direction = more conservative transformation — never omission, never refusal (contrast graphify's degrade-by-omission `{nodes:[], edges:[], error}`).

v3 maturity trajectory (stated 2026-07-27): reposnapshot becomes an **agent-facing MCP server** for repository-level reasoning/investigation; processor coverage expands to common languages + **markdown** + **threadparsing** (tp-perplexity.ps1 is the seed; sibling = jso-jackson claude-export). Snapshot artifacts (sharded, byte-offset manifest, "virtual database" seek contract) are the substrate the MCP tools will expose.

Zero/minimal-dependency bent is deliberate and load-bearing (same epistemic stance as [[project-zero-dependency-epistemics]]): snapshots are exchange artifacts — output must not vary with the producing machine's environment/venv.

**Why:** Azriel corrected an assistant framing that cast handlers as proto-extractors converging on {nodes,edges} emission; that misreads the tool's job and his dependency discipline.

**How to apply:** Never propose extraction/graph emission as the handlers' evolution path (that's [[project_ouroboros]]'s lane). Mine external projects (e.g. [[reference-graphify-extractors]]) for per-language comment/string/doc syntax coverage as config data — not for their failure contracts.

**Caveat (2026-07-27):** this file is an OUT-OF-CONTEXT capture — assembled from fragments surfaced in a ThermoMapper session, where Azriel flagged the assistant as repeatedly missing the point and said bringing reposnapshot up outside its own context was a mistake. Treat this as a pointer with verbatim facts only; reposnapshot's own repo (issues/, .discussion, its sessions) is the authoritative record. Do not extrapolate or riff on reposnapshot design from within ThermoMapper sessions ([[feedback-sibling-projects-facts-not-riffs]]).

## Context

Memory corrected — [project_reposnapshot_contract](C:\Users\azrie.claude\projects\D--aghado01-ThermoMapper\memory\project_reposnapshot_contract.md) now records the handler contract so future sessions don't re-run the proto-extractor misframe, and the graphify reference now points at it.

The distinction is worth stating precisely, because the two tools degrade in opposite directions. Graphify degrades **by omission**: parse failure or missing grammar yields `{nodes: [], edges: [], error}`, and a hole in an analysis cache is survivable. reposnapshot degrades **by conservatism**: when understanding drops, do _less_ transformation, but the output must always still be the code — because the artifact's whole purpose may be carrying the unparseable file to whoever will debug it. Omission is the one behavior a debugging-snapshot tool can never exhibit, so their failure contract is the wrong import even though it superficially resembles yours.

Your dependency point also has a sharper edge than "hygiene": graphify's _output is a function of the producing venv_. PowerShell coverage exists only if an optional pip grammar happens to be installed; the partitioner silently switches between Leiden and Louvain depending on whether graspologic made it into the environment. For a local cache that's a quirk. For an exchange artifact — a snapshot handed across machines and people for debugging — producer-environment-dependent output is a reproducibility defect, full stop. In-host AST plus an explicitly error-ID-gated fallback means identical input yields an identical snapshot everywhere, which is a property their architecture can't state.

So what's left to mine from their lineup is data, not design: the per-language comment/doc/string syntax coverage embedded across those 29 extractors. Your ops vocabulary (`block-comments`, `interior-comments`, `line-comments`, `inline-comments`, `doc-strings`, `comment-blocks`) is already the cross-language axis; the per-language piece is a syntax table — comment forms, string/here-string forms that must be masked rather than scanned — plus the piece where "respects the language" gets concrete: a preserve-list for load-bearing text that is lexically a comment but semantically not strippable. `#Requires` and `#!` lines, `//go:generate`, `# noqa` / `# type: ignore`, `///` doc comments if the config says docs survive. Strippability is a per-form, per-language judgment, and that judgment table is exactly what a handler config surface exists to hold — the shape rs-csstrip's standalone-vs-interior discrimination already gestures at.

Roadmap fact worth pinning to the memory before I respond to it.

Logged. A few observations on that trajectory, roughly in order of how much I think they matter:

**The MCP move converts your manifest's social contract into a structural one.** Right now the tree manifest _asks_ the reading agent to behave — "treat this as a virtual database, seek by offsets, do not grep." That's prose begging for discipline, and it works only as well as the agent's compliance (I nearly violated it myself before you pointed me at the file). Once reposnapshot is the MCP surface, the only operations that exist are the ones you expose: `seek(entry)`, `tree()`, `read-span(shard, offset)`. The grep explosion stops being a warned-against behavior and becomes unrepresentable. That's the same strict-core instinct as your DTO-boundary pattern — the interesting design work is choosing the verb set, because the verb set _is_ the reasoning model you're granting the agent.

**Transformation provenance becomes load-bearing once the consumer is an agent.** A human reading a stripped snapshot knows it's stripped. An agent handed one via MCP will happily conclude "this codebase has no comments, no docs, sloppy hygiene" unless the artifact declares what was removed. The manifest already records Strategy/Grouping/Packing; the processor chain's config (which ops ran, per file class) belongs in there with it, so the reading agent can calibrate its inferences against what it can't see. Your config-artifact-provenance discipline arrives here with a new justification: it's not just reproducibility, it's epistemic honesty toward the consuming model.

**Threadparsing rhymes with your comment taxonomy almost exactly.** A conversation thread has strippable classes the same way source does: tool results, thinking blocks, system reminders, retry noise — synthetic scaffolding versus human/assistant prose. Your Hilbert thread exports already prove you're hand-rolling this ("standard reading profile", "full minus synthetic") — those reading profiles are processor ops configs that just don't know it yet. `tp-*` handlers with an `Operations = @('tool-results', 'thinking', 'system-reminders', ...)` surface would unify the claude-export work and the perplexity seed under the identical Item/Config contract the strippers already share. Same never-break guarantee too: a thread with malformed JSON events still ships, conservatively untouched.

**Markdown is the one target where the handler is naturally a router.** Its preserve-semantics is structure (headings, fences, links), not syntax — and fenced code blocks are foreign inclusions that could dispatch through the chain to the matching language processor, with the fence's info-string as the dispatch key. The chain-executor already composes steps; this would be the first handler that composes _sideways_. Worth deciding early whether that recursion is in-contract or whether fences are opaque spans, because it's the kind of capability that's clean if designed-in and a hairball if retrofitted.

One boundary question to keep in view as coverage expands: whether the shared ops vocabulary stays a fixed core that each language handler _interprets_ (with per-language extensions namespaced, e.g. `ps:here-strings`), or grows organically per handler. The csstrip/psstrip pair is contract-identical today; that property is easy to lose silently around language five or six, and it's the property that makes a single MCP config surface possible at all.
