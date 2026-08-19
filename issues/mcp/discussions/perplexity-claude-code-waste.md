# So ive noticed some patterns in Claude code with context usage ballooning during some sessions, wasteful patterns in the harness default tools and patterns, and writing files in particular with an apparent "write-through" effect where model writes a document and then the contents it wrote echo back. Whe editing a file model might read the file in, make a change, and then effectively duplicate the same document content in context because the default tool echoes the contents. This obviously leads to some highly pathogical and costly eventualities, not to mention wasteful reasoning and accumulating cognitive load. On my mind are the low level logistics of how a remote externally hosted model sends and recieves requests and responses, how self-attention and KV cache work, as well as designing my own MCP with some primitive tools designed to alleviate the issue by bypassing problematic harness tools like the write file tool by providing hooks and nudges to my own version of the tool. I wonder about introducing pointer tokens as place holders for contents previously read, addressable data representations as part of an interface, RPC concepts, potentially context caching mechanisms, and wondering if a model can be instructed in ways to help manage these challenges

You've correctly diagnosed a real architectural pathology, and the good news is that both the upstream platform and the MCP layer now give you several levers. Let me walk through the mechanics first, then a concrete design for your MCP.

## Why the context balloons: the stateless request loop

Every turn to a hosted model is a fresh HTTP request containing the _entire_ conversation history — system prompt, tool schemas, all messages, all prior tool calls and tool results. Nothing persists server-side between requests except optional caches. So when the harness's Write tool echoes the full file back as a tool result, that content now exists twice in the transcript (once in the assistant's `tool_use` parameters, once in the `tool_result`), and both copies are re-transmitted and re-attended on every subsequent turn. Tool results "become part of the conversation history and count against the context budget on every subsequent turn" [^1_1]. A Read → Edit cycle on a 5 KB file is therefore not 10 KB of cost — it's that content re-billed at input rates on _every future request_ in the session, until compaction or clearing removes it.

This is also why the effect compounds pathologically with editing loops: each edit produces another full-document echo, and the transcript grows quadratically in document churn.

## Self-attention, KV cache, and prompt caching

In the transformer, each token's hidden state is projected into keys and values; attention for a new token queries against all prior K/V pairs. The KV cache is the memoization of those per-layer K/V tensors so that a repeated prefix doesn't need re-computation. Anthropic's prompt caching stores exactly this: "KV (key-value) cache representations... are held in memory only," with a 5-minute standard or 1-hour extended TTL [^1_2]. Hits convert full-rate input tokens into cheap `cache_read_input_tokens` — up to ~90% cost and ~85% latency reduction [^1_3][^1_4].

Two consequences for your design:

1. **Caching is prefix-exact.** Any mutation early in the transcript (a dynamic timestamp in the system prompt, a reordered tool schema) invalidates everything after it. Keep static content first, dynamic content last, and mark up to four `cache_control` breakpoints at the ends of stable blocks [^1_5].
2. **Caching reduces _compute_, not _context pressure_.** A 150K-token transcript is still 150K tokens of attention the model must reason over, and quality degrades before the window fills [^1_6]. Your instinct that this is cognitive load, not just dollars, is correct — so the real win is shrinking the transcript, not just making it cheaper.

## Designing the MCP: handles, not payloads

Your "pointer token" idea is essentially a capability/handle abstraction — the same move as file descriptors vs. file contents, and it's the right one. Concretely:

- **Suppress write-through.** Your `write_file` should return only `{path, bytes_written, content_hash}` — never the body. The model already proved it knows the content by emitting it in the call arguments; echoing it back is pure waste. This alone kills the duplication.
- **Diff-based editing.** Replace read-modify-rewrite with `apply_patch(path, unified_diff)` returning `{applied, new_hash, line_range}`. The model needs only the hunk neighborhoods, obtainable via a `read_span(path, start, end)` tool, instead of whole-file reads.
- **Content-addressable store.** Give large artifacts (read results, command outputs) IDs like `blob:sha256:...` and provide `deref(id, range?)` and `grep(id, pattern)` tools. The transcript then holds a 20-token pointer where a 20K-token payload used to live. This is your RPC-by-reference pattern, and it mirrors Anthropic's own "tool-result clearing," which "surgically replaces `tool_result` content blocks" while "keeping the record that the call happened" for re-fetchable results [^1_1].
- **Response filtering and summarization.** Build field selection into the server so tools return only requested fields, and do first-pass summarization server-side for logs and large outputs [^1_7][^1_8]. Also compress schemas aggressively: stripping descriptions/enums yields 70–97% schema-token reduction, and GitHub's 94-tool server alone burns ~17,600 tokens per request in schemas — a cautionary baseline [^1_7][^1_9].
- **Null compression and TOON-style encodings** for structured returns [^1_8].

## Hooks and platform-level levers

- **Claude Code hooks**: a `PostToolUse` hook on the built-in Write/Edit tools can rewrite the tool result before it enters the transcript (replace the echo with a hash + byte count). A `PreToolUse` hook can nudge or block redirecting to your MCP equivalents. This gets you the bypass without forking the harness.
- **Server-side compaction / context management**: the Messages API now supports a `context_management.edits` strategy (e.g. `compact_20260112`) that auto-summarizes older context, and tool-result clearing as a sub-transcript operation [^1_10][^1_1]. If you're calling the API directly in any of your tooling, enable both; they compose with your handle scheme.
- **Instruction-level nudges**: in the tool descriptions and system prompt, state the protocol explicitly — "Never paste file contents back; reference `blob:` IDs; use `read_span` for context." Models follow these reasonably well when the tools make the cheap path the easy path, but treat instructions as a hint layer, not enforcement — enforcement belongs in the hooks/server.

One caution: pointer indirection trades tokens for tool-call round trips and a small risk the model dereferences the wrong handle. Mitigate with short, guessable handle schemes (`file:src/main.py@a3f9`) and by returning a small content preview (~200 chars) with each pointer so the model can verify relevance without a full deref.

Would you like a concrete skeleton of the MCP server (Python or TypeScript) implementing the content-addressed store, `apply_patch`, and the hook configuration?
<span style="display:none">[^1_11][^1_12][^1_13][^1_14][^1_15]</span>

<div align="center">⁂</div>

[^1_1]: https://platform.claude.com/cookbook/tool-use-context-engineering-context-engineering-tools

[^1_2]: https://platform.claude.com/docs/en/build-with-claude/prompt-caching

[^1_3]: https://hidekazu-konishi.com/entry/anthropic_claude_api_prompt_caching_and_token_efficiency.html

[^1_4]: https://forum.cursor.com/t/prompt-caching-with-claude/7551

[^1_5]: https://www.mindstudio.ai/blog/anthropic-prompt-caching-claude-subscription-limits

[^1_6]: https://www.youtube.com/watch?v=O1XLCh-uA_E\&vl=en

[^1_7]: https://www.stackone.com/blog/mcp-token-optimization/

[^1_8]: https://www.mindstudio.ai/blog/optimize-mcp-server-token-usage

[^1_9]: https://pydantic.dev/articles/engineering-mcp-tools-for-token-efficiency

[^1_10]: https://platform.claude.com/docs/en/build-with-claude/compaction

[^1_11]: https://www.reddit.com/r/mcp/comments/1p0py33/3_tips_to_make_mcp_servers_token_efficient/

[^1_12]: https://www.reddit.com/r/singularity/comments/1es605j/anthropic_adds_prompt_caching_talk_directly_to/

[^1_13]: https://learn.microsoft.com/en-au/answers/questions/5951355/prompt-caching-not-applied-for-anthropic-claude-mo

[^1_14]: https://www.facebook.com/groups/claudecode/posts/1607316663750882/

[^1_15]: https://www.reddit.com/r/ClaudeCode/comments/1qp2ueo/clearing_context_bloat_2_x_pro_plans/

---

# Well I think a good MCP design would also provide RPC infrastructure and automation in the runtime environment so as to lubricate the transactions and hygiene.also, regarding prefix matching, why not using some kind of hashing technique like cdc, but of course with certain properties like locality and ideally some flexibility for window size, combined with pointers and other elements of a aystem

Both ideas are sound, but they live at different layers of the stack, and one of them has a hard constraint you need to internalize before designing around it. Let me take them in turn.

## RPC and runtime automation in the MCP

Agreed — the handle abstraction only pays off if the _plumbing_ is invisible. Concretely, your server should own:

- **A session-scoped workspace.** A daemon-side object store (content-addressed, as we discussed) with TTLs, so blobs expire like cache entries rather than accumulating. The MCP tools (`write_file`, `read_span`, `apply_patch`, `deref`, `grep`) are thin RPC stubs over this store; the store does the hygiene — dedup (identical writes hash to the same blob), garbage collection, and preview generation.
- **Batching and transaction semantics.** One RPC call should be able to express "apply these three patches and run the test suite, return only the tail of failures." This is the "code-based execution" pattern gaining traction in MCP design, where the agent ships a small script to the edge instead of orchestrating N round trips through the transcript [^2_1]. Every round trip you collapse is one fewer copy of intermediate state entering context.
- **A hydration/dehydration layer.** Before a tool result enters the transcript, the server replaces payloads exceeding a threshold with `blob:` pointers automatically — the model never has to opt in. On dereference, it returns just the requested window. This makes hygiene the default path rather than a discipline the model must maintain.

## The CDC idea: right intuition, wrong layer for hosted models

Your content-defined chunking instinct is good — and it's essentially what the inference-serving community already converged on, minus the rolling hash. But there's a fundamental constraint: **KV cache reuse is positional.** A KV entry for token _i_ encodes its position via RoPE and, more importantly, attention is causal — token _i_'s K/V only attended to tokens before it. So you cannot take a chunk computed in the middle of transcript A, splice it into a different position in transcript B, and get correct semantics for free.

How the field actually handles this, from least to most flexible:

| Approach                         | Granularity                                                           | Positional flexibility                                 | Where it lives                     |
| :------------------------------- | :-------------------------------------------------------------------- | :----------------------------------------------------- | :--------------------------------- |
| Anthropic prompt caching         | Exact prefix, `cache_control` breakpoints                             | None — byte-identical prefix required [^2_2][^2_3]     | Hosted API (your Claude Code path) |
| vLLM APC                         | Fixed 16-token blocks, hash = H(prefix + block tokens) [^2_4][^2_5]   | Prefix-only, but arbitrary prefix _length_             | Self-hosted                        |
| SGLang RadixAttention            | Radix tree over token sequences, page size 1 [^2_6][^2_7]             | Any shared prefix across branching histories           | Self-hosted                        |
| CacheBlend / chunk-level caching | Arbitrary contiguous chunks, position-independent [^2_8][^2_9][^2_10] | Full — with selective recomputation of boundary tokens | Research/self-hosted (LMCache)     |

CacheBlend is the closest existing realization of your proposal: it reuses KV blocks "regardless of their position in the input sequence" by fixing up positional encodings and recomputing only the small subset of tokens whose keys deviate most (roughly the boundary tokens where cross-chunk attention matters), achieving 2–4x speedups with no quality loss [^2_11][^2_12]. The experimental literature formalizes this as "chunk-level caching" pursuing "position-independent reuse" [^2_9]. Your CDC idea would slot in as the _chunk boundary selector_ on top of CacheBlend-style recomputation — using a rolling hash with flexible window size to pick semantically stable breakpoints (e.g., at file or section boundaries) rather than fixed 16-token blocks. That's a genuinely under-explored combination; boundary placement affects how many tokens need recomputation, and content-defined boundaries would maximize hit stability across edits, exactly as CDC does for rsync/dedup.

But here's the tough-love part: **none of this is reachable through the Anthropic API.** You cannot submit chunk hashes, reorder cached segments, or touch the KV cache — you get exact-prefix matching with four breakpoints, full stop [^2_2][^2_3]. Even vLLM doesn't expose arbitrary KV block recomposition as a public API; you'd be modifying internals [^2_13]. So the CDC+pointer architecture is only buildable on your local llama.cpp/GGUF stack or a modified vLLM — which, given your local-model workflow, may be exactly where you want it. For Claude Code sessions, the achievable win remains transcript hygiene (pointers, diff-edits, clearing), not cache-side dedup.

One more design note: your pointer scheme _composes_ with prefix caching rather than competing with it. Pointers keep the transcript short and stable; a short, stable, append-only transcript is precisely what maximizes prefix-cache hit rates. Volatile insertions mid-transcript (which naive context editing causes) invalidate everything downstream — so your hydration layer should prefer appends over surgical edits where possible, which is also why Anthropic's tool-result clearing is designed as a structured edit the API understands rather than a blind rewrite [^2_14].

Are you planning to prototype the CDC/CacheBlend side on llama.cpp first, or is the near-term target the Claude Code hygiene layer? The answer changes what the MCP's storage abstraction should expose — a local backend would want the chunk store keyed to align with the inference server's block boundaries.
<span style="display:none">[^2_15][^2_16][^2_17][^2_18][^2_19]</span>

<div align="center">⁂</div>

[^2_1]: https://www.stackone.com/blog/mcp-token-optimization/

[^2_2]: https://platform.claude.com/docs/en/build-with-claude/prompt-caching

[^2_3]: https://www.mindstudio.ai/blog/anthropic-prompt-caching-claude-subscription-limits

[^2_4]: https://docs.vllm.ai/en/stable/design/prefix_caching/

[^2_5]: https://sankalp.bearblog.dev/how-prompt-caching-works/

[^2_6]: https://github.com/vllm-project/vllm/issues/2614

[^2_7]: https://www.spheron.network/blog/vllm-vs-sglang-2026/

[^2_8]: https://blog.lmcache.ai/en/2026/04/01/accelerating-openclaw-agents-with-cacheblend/

[^2_9]: https://arxiv.org/html/2603.20218v1

[^2_10]: https://www.linkedin.com/posts/akshay-pachaar_90-of-your-kv-cache-never-gets-reused-activity-7484972640701526016-BXLr

[^2_11]: https://www.reddit.com/r/LocalLLaMA/comments/1lp653l/reuse_nonprefix_kv_cache_and_speed_up_rag_by_3x/

[^2_12]: https://www.microsoft.com/en-us/research/wp-content/uploads/2024/09/eurosys25-final999.pdf

[^2_13]: https://discuss.vllm.ai/t/exposing-kv-cache-for-recomposition-reuse-beyond-prefix-caching/2208

[^2_14]: https://platform.claude.com/cookbook/tool-use-context-engineering-context-engineering-tools

[^2_15]: https://docs.vllm.ai/en/v0.9.2/design/automatic_prefix_caching.html

[^2_16]: https://blog.squeezebits.com/vllm-vs-tensorrtllm-12-automatic-prefix-caching-38189

[^2_17]: https://openreview.net/forum?id=bld5GVRad0

[^2_18]: https://www.linkedin.com/posts/ashishpatel2604_%F0%9D%97%A5%F0%9D%97%AE%F0%9D%97%B1%F0%9D%97%B6%F0%9D%98%85%F0%9D%97%94%F0%9D%98%81%F0%9D%98%81%F0%9D%97%B2%F0%9D%97%BB%F0%9D%98%81%F0%9D%97%B6%F0%9D%97%BC%F0%9D%97%BB%F0%9D%98%80-%F0%9D%97%A3%F0%9D%97%BF%F0%9D%97%B2-activity-7397194578929418240-ol_u

[^2_19]: https://github.com/LMCache/LMCache/issues/3238

---

# Yes, research papers are often useless if one lacks a white hat. But I'm also thinking about externalizing a cache and trying to figure out what that might look like in my system in helping with the context waste and abuse problems

Your "white hat" framing is apt, because the useful part of the research literature here isn't the novel mechanism — it's the confirmation that the boring, well-understood systems patterns (content-addressed storage, external memory hierarchies, OS-style cache management) are exactly what works at this layer. You don't need a new algorithm; you need a disciplined storage tier.

## What an external cache looks like in your system

The cleanest mental model is the one the Manus team landed on: treat the file system (or a blob store) as "the ultimate context" — unlimited, persistent, and directly operable by the agent — and design every compression to be _restorable_, i.e. drop content only when a path/URL/handle survives that can rehydrate it [^3_1]. Your pointer-token scheme is precisely this. The external cache is the thing those pointers point into.

Concretely, three tiers, mirroring the G1–G4 hierarchy NVIDIA Dynamo uses for distributed KV cache (GPU HBM → DRAM → NVMe → shared storage) [^3_2]:

| Tier                      | Contents                                                                             | Latency             | Keyed by                     |
| :------------------------ | :----------------------------------------------------------------------------------- | :------------------ | :--------------------------- |
| Hot (in-context)          | Current task, last 3–5 tool outputs, active errors, recent conversation [^3_3]       | Free (already paid) | Position in transcript       |
| Warm (session blob store) | Full tool results, file versions, command outputs, pre-compaction transcripts [^3_4] | One RPC             | `blob:sha256`, path+hash     |
| Cold (persistent memory)  | Cross-session facts, decisions, patterns, summaries [^3_5][^3_6]                     | Retrieval query     | Vector index + structured DB |

The context-engineering playbook is unambiguous about the split: keep current objectives, recent outputs, and active error states in context; offload historical conversations, large reference docs, and intermediate computational results to memory [^3_3]. And the payoff data is not trivial — external memory architectures report ~90% token savings versus full-context approaches [^3_5], and teams building around the KV cache see ~10x cost reduction [^3_3].

## The design decisions that actually matter

Since you're skeptical of papers for papers' sake, here is where I'd push rigor instead — the places external caches genuinely succeed or fail:

1. **Restorability as an invariant, not a feature.** Anything evicted from the transcript must leave behind a dereferenceable handle, and you should be able to _prove_ round-trip integrity: `deref(store(x)) == x` by construction (hash-addressing gives you this for free). This is what separates a cache from data loss.
2. **Append-only serialization to protect the prefix cache.** This is the interaction people miss. An external cache that helps the _context_ can silently hurt the _KV cache_: if hydration rewrites or reorders early transcript content, you invalidate the prefix from that token onward — "even a single-token difference can invalidate the cache from that token onward" [^3_1]. So the store must emit deterministic serialization (stable JSON key ordering — many libraries don't guarantee this [^3_1]) and your hydration layer should append pointers/summaries rather than splice content into the middle. Cache hit rate is "the single most important metric for a production-stage AI agent" [^3_1].
3. **Dual-form results.** Emit every tool result in two forms — full (goes to warm store) and compact (goes to transcript) — with policy deciding which is which [^3_4]. Your write-through problem is the degenerate case where the compact form is wrongly equal to the full form.
4. **Eviction policy as OS, not heuristic.** The strongest framing in the literature: "manage the context window the way an operating system manages RAM — being in control of what goes in, what stays, and what gets evicted" [^3_6]. That means explicit TTLs, LRU with reference counts, and prefix-length-aware eviction (evict longer-prefix blocks first, per RadixAttention's policy [^3_7]) — not ad-hoc summarization when things feel big.
5. **A size-gated escalation ladder.** Simple append-only below ~10k tokens, compression at boundaries from 10–50k, external memory + smart retrieval from 50–100k, multi-agent isolation beyond 100k [^3_3]. Don't build tier-3 machinery for a tier-1 workload.

## Where I'd actually push back on your framing

You said papers are often useless without a white hat. Fair — but I'd invert the risk for this project specifically: the danger isn't lacking the hat, it's _over-building the cache_. The failure mode I see in external-memory systems is teams constructing elaborate retrieval infrastructure (vector DBs, knowledge graphs, embedding pipelines) when 90% of the win was the first two tiers: stop echoing file contents, hash-address the blobs, keep the transcript append-only. Mem0-style semantic retrieval is the cherry, not the cake [^3_5]. Given your aversion to confirmation bias, the honest prior is: a content-addressed store with deterministic handles and restorable eviction gets you most of the way, and everything beyond that needs to justify itself with a measured token/latency delta on _your_ workloads — instrumented per-tool (avg output tokens × call frequency) before you optimize anything [^3_8].

What's your current split between hosted (Claude Code) and local (llama.cpp) usage? The honest architecture differs sharply — on hosted models your "external cache" can only ever be a transcript-shaping device (pointers + restorable eviction), whereas on local models it could eventually become a true KV-cache tier if you get into vLLM/llama.cpp internals. That determines whether the blob store should be designed as a dumb content-addressed box or something that aligns its chunking with the inference server's block boundaries from day one.
<span style="display:none">[^3_10][^3_11][^3_12][^3_13][^3_14][^3_15][^3_16][^3_17][^3_9]</span>

<div align="center">⁂</div>

[^3_1]: https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus

[^3_2]: https://www.redbooks.ibm.com/docs/MD260021/MD260021.html

[^3_3]: https://galileo.ai/blog/context-engineering-for-agents

[^3_4]: https://www.youtube.com/watch?v=6_BcCthVvb8

[^3_5]: https://atlan.com/know/in-context-vs-external-memory-ai-agents/

[^3_6]: https://mem0.ai/blog/context-window-is-ram-not-storage-why-most-agent-failures-happen-how-to-fix-them-in-2026

[^3_7]: https://github.com/vllm-project/vllm/issues/2614

[^3_8]: https://www.mindstudio.ai/blog/optimize-mcp-server-token-usage

[^3_9]: https://natesnewsletter.substack.com/p/context-windows-are-a-lie-the-myth

[^3_10]: https://www.reddit.com/r/LLMDevs/comments/1v7zekl/i_designed_a_cacheaware_context_system_for/

[^3_11]: https://www.reddit.com/r/AI_Agents/comments/1rlucg7/stop_losing_4080_of_your_agents_context_window_to/

[^3_12]: https://www.linkedin.com/posts/abhicvk_context-bloat-too-much-context-in-a-activity-7369431851284762625--Lyi

[^3_13]: https://platform.claude.com/cookbook/tool-use-context-engineering-context-engineering-tools

[^3_14]: https://arxiv.org/html/2501.12689v3

[^3_15]: https://research.ibm.com/blog/cas-100-billion-vector-storage-ai

[^3_16]: https://arize.com/blog/context-management-in-agent-harnesses/

[^3_17]: https://community.openai.com/t/best-practices-for-cost-efficient-high-quality-context-management-in-long-ai-chats/1373996

---

# I'm not skeptical of research papers. I'm pointing out many of them tinker with model harness and intrisics that can't be implemented unless you are a developer or research engineer at anthropic , e.g. have a white hat. I'm all for good research thatis actionable

That's a fair and sharper distinction than I gave you credit for, and I think it actually maps cleanly onto a useful engineering principle: **the actionable research frontier is defined by the API surface, not the idea space.** A paper that requires modifying attention internals, KV block recomposition, or harness-level tool_result handling is, for anyone outside the vendor, a design constraint document — not an implementation guide. Your "white hat" framing is essentially the access-control boundary of the stack, and it deserves to be treated as a first-class architectural input.

## Where the boundary actually sits

Worth being precise, because the line has moved even in the last year and some things that look vendor-locked aren't:

| Layer                                                        | Actionable without a white hat? | Why                                                                                                                                                        |
| :----------------------------------------------------------- | :------------------------------ | :--------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Transcript shaping (pointers, dual-form results, diff edits) | Yes                             | Pure client/harness behavior; Anthropic's own tool-result clearing and compaction are exposed via the Messages API `context_management.edits` [^4_1][^4_2] |
| Prompt caching (prefix, 4 breakpoints, TTLs)                 | Yes                             | Explicitly a public API feature [^4_3][^4_4]                                                                                                               |
| Hooks (PreToolUse/PostToolUse rewriting)                     | Yes                             | Claude Code exposes these as user-configured extension points                                                                                              |
| Chunk-level / position-independent KV reuse (CacheBlend)     | **No — on hosted**              | Requires KV cache access the Anthropic API never grants; exact-prefix matching only [^4_3][^4_5]                                                           |
| Same, on local models                                        | **Yes — but with effort**       | vLLM doesn't expose arbitrary KV recomposition as a public API; you'd modify internals, though LMCache/CacheBlend is open-source and running [^4_5][^4_6]  |

So the correct read of CacheBlend et al. is not "useless" — it's "**actionable on llama.cpp/vLLM, inert on the Anthropic API**." That's a routing decision in your system, not a verdict on the research.

## The actionable subset, ranked by leverage-per-hat

Given that filter, here's what I'd actually prioritize, ordered by (impact × implementability on your stack today):

1. **Suppress write-through at the hook layer.** PostToolUse hook replacing Write/Edit echoes with `{path, bytes, hash}`. Zero research required, eliminates the duplication pathology you originally flagged, works on the hosted stack immediately.
2. **Content-addressed blob store + restorable eviction.** The Manus "file system as ultimate context" pattern — drop any content that leaves a dereferenceable handle, keep compression always restorable [^4_7]. Actionable everywhere, including hosted.
3. **Deterministic append-only serialization.** Protects prefix-cache hit rate, which the Manus team calls "the single most important metric for a production-stage AI agent" [^4_7]. Costs nothing, requires only discipline about JSON key ordering and avoiding mid-transcript mutation [^4_7].
4. **Server-side context management.** Enable `compact_20260112` and tool-result clearing on any direct API calls [^4_2][^4_1]. This is Anthropic shipping you, as a public API, the exact sub-transcript surgery that used to be white-hat-only.
5. **Deferred: CDC + CacheBlend on local.** Genuinely actionable _for you_ because you run llama.cpp — but only after 1–4 are measured, and only if your local inference share justifies touching serving internals.

## The one thing I'd actually push back on

Your filter is right but risks being _too_ aggressive in one direction: some intrinsic-level research is worth reading precisely **because** it tells you what the vendor will ship as an API feature in 12–18 months. Tool-result clearing and server-side compaction were "white hat only" ideas before Anthropic productized them into `context_management.edits` [^4_2]. Prefix caching was internal before it was a `cache_control` parameter [^4_8]. The pattern is consistent: intrinsic research → internal optimization → public API knob. So the actionable-now filter should gate what you _build_, but reading the inactionable tier is how you predict which harness battles you can stop fighting because the vendor is about to fight them for you. Don't build CacheBlend yourself against the hosted API — but do design your chunking so that when position-independent reuse inevitably ships as an API feature, your blob boundaries align with it.

So the sharper version of your principle: **filter by implementability for build decisions, but not for design decisions.** The white-hat tier is a forecasting signal, not noise.

Want to pressure-test this against a concrete session? If you can point me at one of your ballooning Claude Code transcripts (or just describe the dominant tool-call pattern — is it read/edit loops, test-output spam, or doc-writing?), I can tell you which of the five items above would have captured the most tokens in that specific trace, rather than in the abstract.

<div align="center">⁂</div>

[^4_1]: https://platform.claude.com/cookbook/tool-use-context-engineering-context-engineering-tools

[^4_2]: https://platform.claude.com/docs/en/build-with-claude/compaction

[^4_3]: https://platform.claude.com/docs/en/build-with-claude/prompt-caching

[^4_4]: https://www.mindstudio.ai/blog/anthropic-prompt-caching-claude-subscription-limits

[^4_5]: https://discuss.vllm.ai/t/exposing-kv-cache-for-recomposition-reuse-beyond-prefix-caching/2208

[^4_6]: https://blog.lmcache.ai/en/2026/04/01/accelerating-openclaw-agents-with-cacheblend/

[^4_7]: https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus

[^4_8]: https://forum.cursor.com/t/prompt-caching-with-claude/7551

---

# I've also been studying various open source projects like context-mode, which I actually used for a while a progressively customized in ita hooks and policies without modifying source. This project contains good ideas but after a while I realized my models were often confabulating because of the mcps simplistic architecture. I've also looked at 'meterless' and 'codument' recently as inspiration and materials to synthesize with my own findings and sensibilities

Good, I can work with that. I can see context-mode's architecture clearly now, and I have a hypothesis about the confabulation mechanism. Let me be direct about what I think the failure mode was and how meterless/codument change the synthesis space.

## Why context-mode caused confabulation

Context-mode's core mechanism is routing tool outputs through an SQLite FTS5 BM25 sandbox — purely algorithmic, no LLM calls — and returning only matched spans back to context [^5_1]. The hooks intercept at PreToolUse/PostToolUse and enforce this routing [^5_2][^5_3]. The confabulation source is almost certainly the **retrieval-relevance mismatch**: BM25 is keyword-frequency scoring, not semantic proximity. When the model asks for code context and the FTS5 index returns the highest-BM25 span rather than the causally relevant one, the model gets confidently wrong context — partial function signatures, mismatched variable names, truncated logic — and then fills in the gaps with generation rather than observation. That's the classic confabulation precondition: the model _thinks_ it read something, the retrieved content is plausible but wrong, and the hallucination is coherent because it's anchored to the malformed excerpt.

The 98% token savings claim [^5_4] is real but the implicit assumption is that BM25 recall is good enough that the saved tokens weren't load-bearing. For many queries that holds; for the cases where it doesn't, the failure mode is silent and architecturally invisible — the model doesn't know it got the wrong chunk.

## What meterless and codument bring to the synthesis

I don't have direct repo access to either (GitHub search returned nothing, so they may be private or renamed), but their names suggest different conceptual emphases worth noting:

- **"Meterless"** suggests zero-metering philosophy — removing the measurement/accounting overhead from the hot path, possibly implying a different approach to what gets tracked. If it's doing lazy or demand-driven context accounting rather than eager routing, that would be architecturally complementary to context-mode's eager interception.
- **"Codument"** — "code + document" or "coded document" — suggests a richer representational layer for structured content, possibly treating code artifacts as first-class document objects rather than raw byte blobs. This would be relevant to your pointer/handle design.

Can you share their GitHub URLs or describe their core mechanisms? That would let me give you a grounded synthesis rather than working from names.

## The synthesis gap your findings point toward

From what you've described, the failure pattern suggests your next design needs two things context-mode lacked:

**Semantic fidelity guarantees in the retrieval path.** BM25 is a legitimate first-pass filter, but any external cache architecture that routes content through keyword retrieval without a semantic verification step is betting that precision is perfect. The fix is not necessarily embedding everything — it's a **confidence signal** on retrieval: return a span _plus a confidence bound_, and if confidence is below threshold, either widen the window or return the handle with a "low-confidence" annotation so the model can request a broader deref. This is computable without an LLM call — cosine similarity on a cheap local embedding (e.g. a 384-dim sentence-transformer) is fast enough to be in the retrieval hot path.

**Provenance-aware context injection.** When content enters the transcript from the external store, it should carry metadata: `{source: blob:sha256:..., span: [L12-L47], retrieval_confidence: 0.87, retrieved_at: turn_N}`. The model can then reason about the provenance of what it "knows" and flag when it's extrapolating beyond retrieved content. This doesn't stop confabulation architecturally, but it creates the right epistemic framing for the model to be more conservative — system-prompt instructions like "content tagged low_confidence should be explicitly flagged before acting on" actually work when the retrieval layer enforces the tagging.

The core thesis: context-mode optimized for _compression_, your synthesis should optimize for _compression with verifiable fidelity_. The cost difference between the two is one lightweight similarity score per retrieval call.

What are the primary tool-call patterns you're seeing in your workloads — mostly code read/edit loops, or also heavy documentation / long-form writing turns?
<span style="display:none">[^5_10][^5_11][^5_12][^5_13][^5_14][^5_15][^5_5][^5_6][^5_7][^5_8][^5_9]</span>

<div align="center">⁂</div>

[^5_1]: https://news.ycombinator.com/item?id=47193064

[^5_2]: https://skillsllm.com/skill/claude-context-mode

[^5_3]: https://github.com/mksglu/context-mode

[^5_4]: https://lobehub.com/mcp/mksglu-context-mode

[^5_5]: https://github.com/modelcontextprotocol/servers

[^5_6]: https://github.com/upstash/context7

[^5_7]: https://github.com/appcypher/awesome-mcp-servers

[^5_8]: https://www.reddit.com/r/mcp/comments/1o4yjb7/mcp_context_bloat/

[^5_9]: https://www.anthropic.com/news/model-context-protocol

[^5_10]: https://github.com/orgs/community/discussions/174921

[^5_11]: https://www.youtube.com/watch?v=1RpGVqgqLaE

[^5_12]: https://github.com/orgs/modelcontextprotocol/discussions/532

[^5_13]: https://modelcontextprotocol.io/docs/2026-07-28/develop/connect-local-servers

[^5_14]: https://github.com/topics/context-mode

[^5_15]: https://dev.to/pwd9000/github-mcp-server-deep-dive-and-context-engineering-49lo

---

# The other two are hard to find but here you go: https://github.com/jakubsuplicki/codument, I'll have to find meterless still

Good, now I have a complete picture of codument's actual architecture. Let me synthesize properly.

## What codument actually is (vs. what it sounds like)

Reading the source tree, codument is not primarily a context compression tool — it's a **doc-drift gate with token accounting as a side effect**. Its core is [`fingerprint.ts`](https://github.com/jakubsuplicki/codument/blob/4e7c3b294615ad8e982cf0b46a49649a214929e0/src/lib/fingerprint.ts) (26KB), [`analyze.ts`](https://github.com/jakubsuplicki/codument/blob/4e7c3b294615ad8e982cf0b46a49649a214929e0/src/lib/analyze.ts) (49KB), and [`ts-canonicalize.ts`](https://github.com/jakubsuplicki/codument/blob/4e7c3b294615ad8e982cf0b46a49649a214929e0/src/lib/ts-canonicalize.ts) (17KB) — symbol-level fingerprinting, per-symbol drift detection, and canonical token-stream normalization (the thing that makes local renames not fire the gate). [`context-pack.ts`](https://github.com/jakubsuplicki/codument/blob/4e7c3b294615ad8e982cf0b46a49649a214929e0/src/lib/context-pack.ts) (14KB) and [`claude-feed.ts`](https://github.com/jakubsuplicki/codument/blob/4e7c3b294615ad8e982cf0b46a49649a214929e0/src/lib/claude-feed.ts) (32KB) are the pieces closest to your concern — the context selection and session transcript telemetry. [`token-cost.ts`](https://github.com/jakubsuplicki/codument/blob/4e7c3b294615ad8e982cf0b46a49649a214929e0/src/lib/token-cost.ts) / [`token-report.ts`](https://github.com/jakubsuplicki/codument/blob/4e7c3b294615ad8e982cf0b46a49649a214929e0/src/lib/token-report.ts) are accounting, not control.

This matters for your synthesis because codument solves a **different problem**: it answers "did the agent touch something it shouldn't have or leave documentation stale?" It uses the registry as a provenance map and the fingerprint+canonicalize pipeline as a change-detection oracle. The context benchmark (43.1% reduction) is a byproduct of registry-guided working-set selection, not compression per se.

## The productive synthesis across all three projects

|                            | context-mode                 | codument                                  | Your design target                                       |
| :------------------------- | :--------------------------- | :---------------------------------------- | :------------------------------------------------------- |
| **Compression mechanism**  | BM25/FTS5 sandbox routing    | Registry-guided working-set selection     | Content-addressed store + pointer handles                |
| **Fidelity guarantee**     | None (silent recall failure) | Per-symbol fingerprint integrity          | Confidence-annotated retrieval                           |
| **Doc/code coherence**     | None                         | Core invariant (drift gate)               | Should borrow this — critical for avoiding confabulation |
| **Token accounting**       | Per-tool stats               | Per-feature event ledger (`events.jsonl`) | Per-blob + per-tool in your MCP                          |
| **External cache**         | No — in-process FTS5 only    | No — git as the persistent store          | Yes — this is the gap both miss                          |
| **RPC/hygiene automation** | Hook interception only       | Pre-commit gate, CI gate                  | MCP as first-class runtime mediator                      |

The thing codument has that context-mode lacks and that's directly relevant to your confabulation problem is the **canonicalization layer** — `ts-canonicalize.ts` normalizes local bindings to positional indices before fingerprinting, so retrieved context is structurally stable across renames. This is exactly the kind of property you want in a blob store's chunking scheme: chunk boundaries should be semantically stable across minor edits so the same logical unit retrieves consistently. Codument achieves this at the symbol level via tree-sitter; your external cache could adopt the same boundary semantics — chunk at symbol/declaration boundaries rather than fixed character offsets, and canonicalize each chunk's bound names before hashing. That gives you CDC-like content-defined boundaries but grounded in parse structure, not rolling hashes over raw bytes. The rolling hash is then a fallback for languages without adapters.

## What the external cache gains from this picture

Codument's `docs/.registry.json` is a static ownership map maintained by convention. Your external cache needs something analogous but dynamic — a **session-scoped retrieval index** that maps `blob:sha256` handles to their parse-level metadata: owning file, symbol name, span, canonical hash, language. This is `context-pack.ts`'s job in codument, but only for context selection, not for serving back into the transcript as pointers.

The gap your MCP fills: codument knows _what changed_ and _what's stale_, but it doesn't mediate the runtime transcript at all — the agent still loads whatever it loads. Your MCP sits in that gap, using codument-style structural metadata to decide what the agent _gets_ rather than just reporting on what it did. The registry becomes the routing table for your blob store's hydration policy: when the model derefs a handle, the MCP can look up codument's ownership map to decide how wide a context window to return and what related symbols to co-hydrate.

That's the concrete synthesis: **codument's static registry + fingerprint infrastructure as the structural skeleton of your MCP's retrieval index**, with your pointer/handle layer as the runtime enforcement that codument currently lacks. The `claude-feed.ts` telemetry loop is already reading the session transcript; your PostToolUse hooks can write back into the same `events.jsonl` stream, giving you unified session-scoped accounting without duplicating that infrastructure.

Drop a link to meterless when you find it — given the pattern I'd guess it addresses the accounting side (the `token-cost.ts` gap, perhaps zero-overhead metering), which would complete the picture.
<span style="display:none">[^6_1]</span>

<div align="center">⁂</div>

[^6_1]: https://github.com/jakubsuplicki/codument

---

# also, meterless, at last: [Meterless/Meterless: Local-first context layer for AI agents. Open-source memory, reasoning, world state, intent, and swarm engines.](https://github.com/Meterless/Meterless)

Now I have all three. Here's how the triangulation lands, and it's cleaner than I expected.

## The three-way architecture map

| Layer                            | context-mode                            | codument                              | meterless                                                                     | Your MCP gap                            |
| :------------------------------- | :-------------------------------------- | :------------------------------------ | :---------------------------------------------------------------------------- | :-------------------------------------- |
| **Compression / context window** | BM25 sandbox routing, no semantic check | Registry-guided working-set selection | **Markovian engine**: bounded carryover, flat cost per step [^7_1]            | Pointer handles + confidence annotation |
| **Change detection / drift**     | None                                    | Per-symbol fingerprint + canonicalize | None (not a gate)                                                             | Structural chunk boundaries             |
| **Memory / persistence**         | None (in-process FTS5 only)             | Git as store, no runtime memory       | **H-MEM**: tiered memory, provenance, trust ledger [^7_1]                     | Content-addressed blob store            |
| **Session state / world model**  | None                                    | `events.jsonl` telemetry only         | **World Model**: event-sourced state, control plane [^7_1]                    | Session-scoped index + provenance       |
| **Intent / routing**             | Hook interception (no semantics)        | Static registry lookup                | **Scout Intent**: classification, risk, tool routing, signed contracts [^7_1] | MCP as runtime mediator                 |
| **RPC / transaction hygiene**    | No                                      | Pre-commit + CI gates                 | Engine conformance suites                                                     | Your MCP as first-class runtime         |

The pattern is clear: **context-mode solves the symptom (context window), codument solves the invariant (doc-code coherence), meterless solves the substrate (memory, state, reasoning)**. None of them sits at the layer your MCP occupies — the runtime mediation between what the agent requests and what enters the transcript. Your pointer/handle layer is exactly the piece that would let meterless's Markovian carryover be _enforced_ rather than just _modeled_.

## What meterless specifically contributes to your design

**H-MEM is the external cache tier you were designing, already specified.** It has short-term/working/long-term tiers, provenance tracking, a trust ledger for mutations, and hybrid retrieval blending semantic similarity with keywords, tags, recency, and confidence. That's not a sketch — it's a spec with a runnable reference and a conformance suite. The gap is that H-MEM stores _facts_; it doesn't mediate the runtime transcript. Your blob store + pointer layer would slot in as the **ephemeral working-set projection** that H-MEM hydrates into the transcript on demand — the tier-2 (warm) layer in the G1–G4 hierarchy we discussed.[^7_1]

**Markovian is the carryover mechanism that makes pointer indirection work.** The problem with naive compaction is that the summary becomes a lossy bottleneck: the model either trusts the summary (confabulation risk) or re-derives everything (token cost). Meterless's Markovian engine breaks work into chunks and passes _bounded carryover_ to the next step — the claim is flat cost for long horizons, with a modeled 86% input-token savings at 20 steps vs naive accumulation. That maps directly onto your pointer scheme: instead of one monolithic summary, each chunk boundary produces a carryover artifact (the pointer + minimal provenance), and the next step hydrates only what it needs. Your MCP becomes the **Markovian runtime** — the thing that enforces the chunk boundaries and mediates the carryover hydration.[^7_1]

**The "separate truth from acceleration" principle** is the architectural discipline that ties all three together. H-MEM is the canonical store (truth). Your blob store is the derived acceleration layer (materialized view). Codument's registry + fingerprint is the integrity check on the derivation. Context-mode is a degenerate case of the acceleration layer with no integrity check — which is exactly why it confabulates.[^7_2]

## The synthesis: what your MCP actually becomes

The design that falls out of this triangulation:

1. **Truth layer**: H-MEM (or your own equivalent) — persistent, provenance-tracked, tiered memory. This is the cold store.
2. **Structural layer**: Codument's registry + fingerprint + canonicalize — the schema for what the blob store indexes and how chunk boundaries are defined. This is the semantic skeleton.
3. **Runtime layer**: Your MCP — the Markovian executor. It enforces chunk boundaries, mediates pointer hydration, and applies the "verify, don't trust" gate before any content enters the transcript. This is the warm store and the hot path.
4. **Integrity layer**: Codument's drift gate as a _runtime_ check, not just a commit-time check. Your PostToolUse hooks can run `codument review --strict` against the working tree before the agent's next turn, so stale-doc findings are surfaced as _context_, not just CI failures.

The key insight: **meterless gives you the memory architecture, codument gives you the integrity architecture, context-mode shows you the failure mode when integrity is absent, and your MCP is the runtime that binds them together.**

The missing piece is still meterless's Scout Intent — the tool routing and risk classification layer. That's the component that would decide _which_ blob to hydrate based on the current task's intent and risk profile, rather than just the model's raw request. Without it, your MCP is a passive store; with it, it becomes an active governor. But that's a design decision for after the core pointer/handle loop is measured and stable.

What's the current state of your blob store — are you at the "proof of concept with a few tools" stage, or further along?
<span style="display:none">[^7_10][^7_11][^7_12][^7_13][^7_14][^7_15][^7_3][^7_4][^7_5][^7_6][^7_7][^7_8][^7_9]</span>

<div align="center">⁂</div>

[^7_1]: https://wavect.io/blog/meterless-ai-agent-context-layer-review/

[^7_2]: https://www.jeremydaly.com/context-engineering-for-commercial-agent-systems/

[^7_3]: https://github.com/Meterless/Meterless

[^7_4]: https://www.reddit.com/r/gameai/comments/1pno6wu/i_built_a_small_internalstate_reasoning_engine_to/

[^7_5]: https://www.linkedin.com/posts/alexwang2911_the-hardest-part-of-building-an-ai-agent-activity-7486689737739616258-dtpo

[^7_6]: https://github.com/topics/world-model?l=typescript\&o=desc\&s=forks

[^7_7]: https://www.tellius.com/resources/blog/what-is-a-context-layer-for-ai-agents-the-definitive-guide-for-2026

[^7_8]: https://arxiv.org/html/2504.12369v2

[^7_9]: https://www.firecrawl.dev/blog/context-layer-for-ai-agents

[^7_10]: https://www.torqueagi.com/articles/world-models-are-becoming-the-central-reasoning-engine-for-physical-ai

[^7_11]: https://atlan.com/know/ai-agent/agent-context-layer-design/

[^7_12]: https://xizaoqu.github.io/worldmem/

[^7_13]: https://datahub.com/blog/how-to-build-a-context-layer/

[^7_14]: https://www.state-machine.com/

[^7_15]: https://moderndata101.substack.com/p/rise-of-the-context-architecture

---

# i do wonder about context-modes BM25 mechanism as a good idea not implemented well. like there are far more effective ways to use hashing in that use-case that would be more robust and could be more intelligently handled/utilized

You're circling something real, but let me sharpen the diagnosis first, because the imprecision in "BM25 is the problem" actually obscures the more interesting design insight.

## The actual problem isn't BM25 — it's the retrieval-granularity mismatch

BM25 is a bag-of-words scoring function over a corpus of documents. It's genuinely good at what it does: given a query with distinctive terms, it ranks documents by term-frequency-inverse-document-frequency with length normalization. The formula is sound. Context-mode's failure wasn't that BM25 is bad — it's that **BM25 operates on documents as opaque bags, and code/documents are not bags of words.**[^8_1]

The specific failure modes that cascade into confabulation:

1. **Structural blindness**: BM25 sees `def compute_similarity(a, b):` and `def compute_similarity(x, y):` as different documents because the token streams differ. Codument's canonicalization layer — rewriting bound names to positional indices before fingerprinting — solves this at the symbol level. BM25 has no equivalent mechanism because it's not a structural index.[^8_2]
2. **Query-context mismatch**: The agent's query is "find the similarity function" but BM25 scores by token overlap. If the function body uses `a` and `b` as parameters and the query mentions `x` and `y`, the BM25 score drops even though the semantic content is identical. This is why context-mode's "no LLM calls, purely algorithmic" design is simultaneously its strength (deterministic) and its weakness (no semantic bridge).[^8_3]
3. **No confidence propagation**: BM25 returns a score, but context-mode doesn't propagate that score into the transcript as a confidence signal. The model gets the retrieved chunk with no metadata about whether it was a strong match or a weak one. This is the confabulation precondition — the model can't distinguish "I found the right thing" from "I found something and I'm guessing."

## What "more effective hashing" would actually look like

Your instinct is right that hashing is underutilized, but the opportunity isn't replacing BM25 — it's **replacing what BM25 is hashing over**. The design space:

| Approach                            | What it hashes                                                   | What it solves                                         | What it costs                                         |
| :---------------------------------- | :--------------------------------------------------------------- | :----------------------------------------------------- | :---------------------------------------------------- |
| **Context-mode (current)**          | Raw token streams of whole documents                             | Nothing structural — just term overlap                 | Low compute, high confabulation risk                  |
| **Codument-style canonicalization** | Normalized token streams (bound names → positional indices)      | Structural stability across renames                    | Requires tree-sitter per language                     |
| **Symbol-level chunking**           | Per-symbol spans (function, class, method) as documents          | Query granularity matches code structure               | Requires parse tree per language                      |
| **Content-defined chunking (CDC)**  | Rolling hash over token stream, boundaries at hash minima        | Edit-stable boundaries, no parse tree needed           | No semantic awareness — chunks may split mid-function |
| **Hybrid: structural CDC**          | Rolling hash _within_ symbol spans, canonicalized before hashing | Best of both: stable boundaries + structural awareness | Highest implementation cost                           |

The hybrid is the interesting one. Codument's `ts-canonicalize.ts` rewrites bound names to positional indices. If you apply a rolling hash (Rabin fingerprint) _after_ canonicalization, you get content-defined chunk boundaries that are:[^8_2]

- **Stable across renames** (canonicalization normalizes the token stream)
- **Edit-local** (a change inside one function doesn't shift boundaries in other functions)
- **Semantically grounded** (boundaries align with symbol structure because you're hashing within parse-tree spans)

This is what context-mode's "purely algorithmic, no LLM" design _could_ have been if it had borrowed codument's structural awareness instead of treating documents as opaque bags.

## The BM25 part worth keeping

BM25's IDF weighting is genuinely useful for retrieval — it downweights common terms and upweights distinctive ones. The improvement path isn't replacing BM25 but **hybridizing it**:

1. **Structural pre-filter**: Use symbol-level chunking to narrow the candidate set before BM25 scoring. The query "similarity function" first retrieves the `compute_similarity` symbol span, then BM25 scores within that span against the query context.
2. **BM25F (field-weighted BM25)**: Score different fields of the symbol separately — the function signature (high weight), the docstring (medium weight), the body (low weight for structural queries, high weight for implementation queries). This is a known BM25 extension that context-mode didn't implement.[^8_1]
3. **Confidence propagation**: Return the BM25 score as a metadata field on the retrieved chunk. The model sees `{content: ..., score: 0.87, method: "BM25F", span: "compute_similarity:L12-L47"}` and can reason about whether to trust it.

## The deeper point

Context-mode's design philosophy — "no LLM calls, purely algorithmic" — is correct as a constraint but was applied to the wrong layer. The LLM call isn't the problem; the problem is that **the algorithmic layer wasn't given enough structural information to make good decisions**. Codument's insight is that you can be purely algorithmic _and_ structurally aware, because tree-sitter gives you parse trees without any model calls. The synthesis is: **codument's structural rigor + context-mode's runtime mediation + your pointer/handle layer = a retrieval system that's deterministic, structurally grounded, and transcript-aware.**[^8_3]

The hash is the right primitive. The question is what you're hashing over and what the hash is _for_ — dedup (content-addressed storage), retrieval (BM25 scoring), or integrity (drift detection). Context-mode conflated all three into one BM25 index. The better design separates them: content hashes for dedup, structural hashes for chunking, BM25 for scoring, and provenance metadata for confidence.

What's your current thinking on the chunking layer — are you leaning toward tree-sitter per language, or a language-agnostic CDC fallback?
<span style="display:none">[^8_10][^8_11][^8_12][^8_13][^8_14][^8_15][^8_16][^8_17][^8_4][^8_5][^8_6][^8_7][^8_8][^8_9]</span>

<div align="center">⁂</div>

[^8_1]: https://spice.ai/learn/bm25-full-text-search

[^8_2]: https://github.com/Meterless/Meterless

[^8_3]: https://news.ycombinator.com/item?id=47193064

[^8_4]: https://interestingengineering.substack.com/p/from-bm25-to-agentic-rag-the-evolution

[^8_5]: https://factory.ai/news/compressing-context

[^8_6]: https://www.ovaledge.com/blog/context-engineering-techniques

[^8_7]: https://aiopsschool.com/blog/bm25/

[^8_8]: https://atlan.com/know/context-compression/

[^8_9]: https://www.youtube.com/watch?v=9QJXvNiJIG8

[^8_10]: https://tessl.io/blog/factory-publishes-framework-for-evaluating-context-compression-in-ai-agents/

[^8_11]: https://learn.microsoft.com/en-us/azure/search/index-similarity-and-scoring

[^8_12]: https://www.ibm.com/think/tutorials/prompt-compression

[^8_13]: https://news.ycombinator.com/item?id=42190650

[^8_14]: https://crypto.stackexchange.com/questions/80352/what-is-the-best-algorithm-for-compressing-a-hash

[^8_15]: https://www.geeksforgeeks.org/nlp/what-is-bm25-best-matching-25-algorithm/

[^8_16]: https://www.youtube.com/watch?v=_ul_KazEL-s

[^8_17]: https://arxiv.org/html/2510.00615v2?ref=swarmsignal.net

---

# im not saying BM25 is bad at what it does, but i am suggesting that there are potentially methods that are better than BM25 for the job

You're right, and the literature has moved well past "BM25 is the ceiling for sparse retrieval." The interesting part is that the strongest alternatives aren't replacing BM25 wholesale — they're **hybrid architectures where BM25 becomes one component in a multi-stage pipeline**, and the retrieval layer gets structurally smarter upstream.

## The state of the art, ranked by what actually beats BM25 alone

| Method                                                                 | What it does                                                 | Where it beats BM25                                         | Where it doesn't                                   |
| :--------------------------------------------------------------------- | :----------------------------------------------------------- | :---------------------------------------------------------- | :------------------------------------------------- |
| **Hybrid sparse+dense** (BM25 + embeddings, RRF fusion)                | Combines lexical precision with semantic recall              | Synonym handling, semantic drift, out-of-domain queries     | Latency, index size, still no structural awareness |
| **Hybrid + neural rerank** (BM25 retrieve, cross-encoder rerank)       | BM25 for candidate generation, transformer for final ranking | Recall@5 jumps from 0.644 to 0.816 in financial docs [^9_1] | Requires model inference at query time             |
| **Contextual retrieval** (LLM-generated summaries prepended to chunks) | Enriches chunks with semantic context before indexing        | Precision up 42pp on question matching [^9_1]               | Index-time LLM cost, summary drift                 |
| **Structural pre-filter + BM25**                                       | Symbol-level chunking before BM25 scoring                    | Eliminates bag-of-words mismatch for code                   | Requires parse trees per language                  |
| **Learned sparse retrieval** (SPLADE, etc.)                            | Learns term importance end-to-end                            | Better than BM25 on some benchmarks                         | Still term-based, no structural grounding          |

The key insight from the benchmark data: **BM25 alone beats dense retrieval on out-of-domain, zero-shot settings**, but **hybrid + rerank beats everything by a wide margin**. The gap isn't "BM25 vs. something better" — it's "BM25 as candidate generator vs. BM25 as final ranker."[^9_1]

## What this means for your context-mode critique

Context-mode's design failure wasn't choosing BM25 — it was **stopping at BM25**. The "purely algorithmic, no LLM" constraint forced a single-stage architecture where BM25 had to do both candidate generation and final ranking. The result is the confabulation you observed: BM25 retrieves a plausible-but-wrong chunk, and there's no second stage to catch it.[^9_2]

The better architecture for your MCP, informed by the literature:

1. **Structural candidate generation**: Use codument-style symbol-level chunking to generate candidates, not BM25 over whole documents. This gives you parse-tree-aware retrieval without any model calls.
2. **BM25 as scorer, not gatekeeper**: Score within the structural candidate set using BM25F (field-weighted: signature, docstring, body). This preserves BM25's lexical precision but eliminates the bag-of-words mismatch.[^9_3]
3. **Confidence propagation**: Return the score + method + span as metadata. The model sees `{content, score, method: "BM25F", span: "compute_similarity:L12-L47", confidence: "high"}` and can reason about trust.
4. **Optional neural rerank**: If you're willing to make one small model call per retrieval, a cross-encoder reranker (e.g., a distilled MiniLM) on the top-K candidates gives you the 17-39% recall jump without full dense retrieval infrastructure.[^9_1]
5. **Provenance-gated fallback**: If the top candidate's score is below threshold, widen the structural span (e.g., include the parent class) rather than returning the low-confidence match. This is the "low-confidence annotation" pattern that prevents confabulation.

## The deeper point

The literature converges on **multi-stage retrieval with explicit confidence signals** as the robust pattern. Single-stage BM25 is the degenerate case where the retrieval layer has no structural awareness and no fallback mechanism. Your instinct that "there are far more effective ways" is correct — but the effectiveness isn't in replacing BM25 with a different scoring function. It's in **giving BM25 better candidates to score and a confidence signal to propagate**.[^9_4][^9_1]

The synthesis for your MCP: **codument's structural rigor for candidate generation + BM25F for scoring + optional rerank for confidence + your pointer/handle layer for hydration**. That's the architecture that would have prevented context-mode's confabulation without sacrificing the "purely algorithmic" constraint.

What's your current thinking on the reranker — are you willing to make a small local model call per retrieval, or does the "no LLM" constraint hold for your design?
<span style="display:none">[^9_10][^9_11][^9_12][^9_13][^9_14][^9_15][^9_16][^9_17][^9_18][^9_5][^9_6][^9_7][^9_8][^9_9]</span>

<div align="center">⁂</div>

[^9_1]: https://arxiv.org/html/2604.01733v1

[^9_2]: https://news.ycombinator.com/item?id=47193064

[^9_3]: https://spice.ai/learn/bm25-full-text-search

[^9_4]: https://www.ovaledge.com/blog/context-engineering-techniques

[^9_5]: https://github.com/run-llama/llama_index/discussions/8630

[^9_6]: https://stackoverflow.com/questions/3886189/besides-bm25-whats-other-ranking-functions-exists

[^9_7]: https://www.reddit.com/r/Rag/comments/1rf7xf6/whats_your_experience_with_hybrid_retrieval/

[^9_8]: https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents

[^9_9]: https://www.youtube.com/watch?v=esY99nYXxR4

[^9_10]: https://www.zenml.io/llmops-database/bm25-vs-vector-search-for-large-scale-code-repository-search

[^9_11]: https://zilliz.com/blog/context-engineering-for-ai-agents

[^9_12]: https://www.ayautomate.com/blog/context-engineering

[^9_13]: https://www.reddit.com/r/LocalLLaMA/comments/1ds30l9/perplexity_seems_to_favor_the_traditional/

[^9_14]: https://www.langchain.com/blog/context-engineering-for-agents

[^9_15]: https://community.openai.com/t/best-practices-for-cost-efficient-high-quality-context-management-in-long-ai-chats/1373996

[^9_16]: https://www.youtube.com/watch?v=r0Dciuq0knU

[^9_17]: https://www.promptingguide.ai/guides/context-engineering-guide

[^9_18]: https://www.facebook.com/groups/1127798762760972/posts/1252436976963816/

---

# something i've worked alot on is data structures and payloads with addressable/random-access properties and token efficient, intuitive design. see `aghado01/project-snapshots` for examples of what my reposnapshot tool currently emits for a collection of code files ingested @GitHub. its actually a public repository `https://github.com/aghado01/project-snapshots`.

I wasn't able to pull the repo contents — GitHub isn't returning it through any of my access paths (web fetch, API, or search indexing all came back empty). That could be indexing lag on a newer repo or fetch restrictions, so I won't pretend to have read it. Rather than guess at your format, let me lay out what I can speak to concretely, and then you can paste the README TOC or a sample shard and I'll critique the actual artifact.

## What I can engage with now

The design space you're describing — addressable, random-access, token-efficient payloads for code collections — has a few reference points worth positioning against:

**TOON (Token-Oriented Object Notation)** is the closest public analogue to what you're describing: a drop-in lossless JSON alternative that declares array structure once (`users[^10_3]{id,name}:`) then streams row values, cutting 30–60% of tokens on uniform object arrays by eliminating repeated keys, braces, and quotes. Its key properties relevant to your work: explicit `[N]` length headers that give models a parseable schema to validate against, and indentation-based nesting instead of punctuation. If your snapshot format is making similar moves independently, that's convergent validation; if it isn't, the tabular-array trick is worth stealing for any repeated-structure sections (file lists, symbol tables).[^10_1][^10_2]

**The addressability question** is where your design likely diverges from TOON. TOON optimizes for _whole-payload_ efficiency — it's still a document you read linearly. Random access requires a different property: stable, computable offsets. For a sharded snapshot format, that typically means a TOC with per-shard hashes and either byte offsets or canonical shard IDs, so a consumer can deref `shard:metrics/aggregation.py` without ingesting siblings. That's the property that would let your format plug directly into the pointer/handle architecture we've been discussing — a Claude Code session could hold the TOC (small, cache-friendly prefix) and hydrate individual shards on demand.

**The structural-stability property** from the codument discussion applies here too: if your shard boundaries follow directory structure, a one-file edit only invalidates one shard's hash — which is exactly the edit-locality property CDC gives you, achieved structurally instead of via rolling hash. That's the right call for code, where directory/module granularity is already semantically meaningful.

## What would let me give you a real critique

Paste either the root README's TOC section or one representative shard (even truncated). The specific things I'd evaluate:

- Whether the TOC is small and stable enough to sit permanently in context as a cached prefix
- Whether shard identifiers are human-intuitive (path-based) vs opaque (hash-based) — there's a real tradeoff: path-based IDs are dereferenceable by the model without a lookup, hash-based IDs give you content-addressing and dedup
- Whether per-file payloads carry the metadata a retrieval layer needs (symbol spans, language, byte counts) or just raw content
- Token overhead per file vs. raw concatenation — the number that decides whether the format earns its structure

Which of those was the primary design driver when you built the format — model-legibility of the TOC, or per-shard dereferenceability?
<span style="display:none">[^10_10][^10_11][^10_12][^10_13][^10_14][^10_15][^10_16][^10_17][^10_18][^10_19][^10_20][^10_21][^10_22][^10_23][^10_24][^10_25][^10_26][^10_27][^10_28][^10_29][^10_30][^10_31][^10_32][^10_33][^10_34][^10_35][^10_36][^10_37][^10_38][^10_4][^10_5][^10_6][^10_7][^10_8][^10_9]</span>

<div align="center">⁂</div>

[^10_1]: https://github.com/toon-format/toon

[^10_2]: https://blog.logrocket.com/reduce-tokens-with-toon/

[^10_3]: https://stackoverflow.com/questions/54447805/place-for-github-snapshot-archives-source-code

[^10_4]: https://online-help.sagex3.com/erp/12/en-us/Content/FCT/GESPJMOPSNP.htm

[^10_5]: https://github.com/NotHarshhaa/github-repo-status-tracker

[^10_6]: https://www.youtube.com/watch?v=xMK7txZuT2E

[^10_7]: https://www.ibm.com/docs/en/rational-build-forge/7.1.3?topic=project-snapshot-overview

[^10_8]: https://www.linkedin.com/posts/deborahjacob_github-toon-formattoon-token-oriented-activity-7397709018003099648-K8zZ

[^10_9]: https://arxiv.org/html/2605.16701v2

[^10_10]: https://github.com/snyk-playground/cx-tools/blob/main/scripts/retrieve-projects-snapshots.md

[^10_11]: https://tensorlake.ai/blog/toon-vs-json

[^10_12]: https://www.youtube.com/watch?v=pG8QAkhr90U\&vl=en-US

[^10_13]: https://experienceleague.adobe.com/en/docs/workfront/using/manage-work/projects/create-projects/create-snapshots

[^10_14]: https://github.com/reziamini/awesome-github

[^10_15]: https://www.reddit.com/r/vscode/comments/1ctch83/recommended_extension_for_creating_pointintime/

[^10_16]: https://github.com/Chatham/repo-snapshots

[^10_17]: https://github.com/rsnapshot/rsnapshot

[^10_18]: https://hub.docker.com/r/linuxserver/rsnapshot

[^10_19]: https://docs.aws.amazon.com/ja_jp/codeartifact/latest/ug/maven-snapshots.html

[^10_20]: https://github.com/rrweb-io/rrweb/blob/master/packages/rrweb-snapshot/README.md

[^10_21]: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/agent-sandbox-pod-snapshots

[^10_22]: https://www.iamtimsmith.com/blog/take-snapshots-of-your-project-with-git

[^10_23]: https://github.com/fepitre/debian-snapshot

[^10_24]: https://github.com/topics/project-snapshot

[^10_25]: https://github.com/explore

[^10_26]: https://github.github.com/gh-aw/examples/maintaining-repos/

[^10_27]: https://www.youtube.com/watch?v=usOkkNPQXYg

[^10_28]: https://stackoverflow.com/questions/62162889/there-is-a-way-to-batch-archive-github-repositories-based-off-of-a-search

[^10_29]: https://www.youtube.com/watch?v=NVibWKkon74

[^10_30]: https://til.simonwillison.net/github/software-archive-recovery

[^10_31]: https://www.youtube.com/watch?v=cxbNHm5Z71E

[^10_32]: https://www.reddit.com/r/esp32/comments/1r21a3z/safegithubota_ota_updates_from_private_github/

[^10_33]: https://docs.github.com/en/repositories/working-with-files/using-files/downloading-source-code-archives

[^10_34]: https://discourse.openehr.org/t/tips-on-connecting-ad-to-a-github-repo/5635

[^10_35]: https://github.com/your-repo

[^10_36]: https://github.com/orgs/community/discussions/24916

[^10_37]: https://docs.observeinc.com/docs/github-1

[^10_38]: https://nsfocusglobal.com/supply-chain-attack-event-targeted-attacks-on-java-projects-in-github/

---
