DESIGN PASS — para-agent MCP. Write a report; I will critique it and send follow-ups.

Shift of task: you are no longer auditing a transcript. You are reviewing a codebase and
proposing improvements. Same discipline about not flooding your context, but you SHOULD
read source here — that is the job.

## Read these

1. D:\aghado01\science-facility\mcp\para-agent\src\ (index.js 30K, journal.js 18K,
   mux.js 15K, framing.js 13K, capture.js 12K) — the implementation.
2. D:\aghado01\science-facility\mcp\para-agent\contract\CONSOLE-CONTRACT.md — the v1 data
   contract. Treat it as the spec the code is meant to satisfy.
3. D:\aghado01\rector-codicis\SHAPE.md and contracts\README.md — the ORIGINAL design this
   node MCP is a prototype of. Note "Open forks" (largest section) and "Operating model".
4. D:\aghado01\science-facility\mcp\para-agent\capture\ParaConsole.psm1 — interactive capture.

## Established findings — do NOT re-derive these, build on them

TURN ECONOMICS

- The harness preamble is ~52,477 tokens, paid on EVERY turn. Itemized from attachment
  records: skill_listing 11,166 chars, deferred_tools_delta 5,927, agent_listing_delta
  2,910, mcp_instructions_delta 1,507. Turn COUNT is the multiplier on all of it.
- A solo Grep returns ~290 tokens for a ~52K round trip. Cheap per byte, ruinous per turn.
- Therefore: any proposal is scored by whether it REMOVES ROUND TRIPS, not whether it
  makes a result smaller.

HOOK MECHANICS (Claude Code)

- PreToolUse is the only SUBTRACTIVE lever: it can deny, or `modify` tool input before the
  call lands. PostToolUse is ADDITIVE ONLY — by the time it runs, output has already formed.
- A denial costs MORE than what it prevents (~52K for the denied turn + ~52K for the retry).
  So denial is only justified when the correct alternative is unambiguous and the retry is
  guaranteed to land. Schema-level prevention is free; JIT guidance is nearly free.
- The harness spawns PowerShell as `-NoProfile -NonInteractive`. Ambient console hooks
  (prompt function, PSReadLine, Start-Transcript) are UNREACHABLE there. They DO work in a
  psmux pane, because that is a persistent interactive host. This is why para-agent exists.

WHY CONTEXT-MODE'S POLICIES ARE BLUNT (root cause, verified in its source)

- Its PreToolUse cannot load SessionDB — better-sqlite3 is a native module and loading it
  corrupts hook stdout. So Pre talks to Post through consume-once temp marker files,
  ONE WAY ONLY. The decision plane can never read the capture plane.
- Consequence: every routing decision is stateless. It cannot ask "already fetched?",
  "third grep this turn?". All it has is one-shot boolean markers. The policies are blunt
  because they are BLIND, not because they are badly written.
- Its actual Grep policy is one line: guidanceOnce("grep", ...). It never inspects pattern,
  path, or result.
- It has to regex-parse bash command strings (stripHeredocs, stripQuotedContent, segment
  splitting on &&/||/;) and still guesses `bytesAvoided: 8192` as a hardcoded constant.
- Worth stealing from it anyway: isStructurallyBounded(command) — asks whether output is
  PROVABLY small rather than matching command names; guidanceOnce/guidancePeriodic —
  throttled JIT injection with atomic O_CREAT|O_EXCL markers and a re-fire counter for
  after compaction eats the first nudge.

PRIOR ART IN THIS WORKSPACE

- vscodepilot ARCHITECTURE.md (2025-11-17) Principle 2, "Format-Based Contract = External":
  the consumer reads JSONL dumps and NEVER imports the producer. ConsoleRecord =
  {type, timestamp, session, seq, command, exit_code}.
- cybernetic-copilot: CyberneticConsole/Observation/Supervision/MemorySystem PowerShell
  modules — prompt-function replacement, transcript slicing by byte offset, Get-History,
  Register-EngineEvent. Automated promotion gates in the memory system.
- rector-codicis contracts/: hooks as DATA not hardcoded regex; hook types command | prompt
  | agent | http, where `agent` = an agentic verifier doing SEMANTIC supervision; typed
  intervention outcomes (blockingError, preventContinuation, stopReason); a constitution /
  aesthetic contract that the para-agent never reads directly — taste propagates via briefs.
- rector-codicis primitives/hashish (C# net10.0, COMPILED AND LOADING): bloom, minhash,
  simhash, ctph, tlsh, countmin, hyperloglog, ncd, jaccard, levenshtein, idf, bm25, tfidf,
  shingler. Nobody has wired this to para-agent or to any hook. Consider whether it is the
  "cheap projection a stateless hook can read in <1ms with no native module."

DESIGN IDEAS ALREADY ON THE TABLE (critique them, do not just restate)

- Receipt inversion: PreToolUse rewrites a verbose invocation into a wrapper that
  externalizes the artifact and prints only a receipt, so spam never forms.
- Three faces for every expensive artifact: receipt (always resident, tiny) / outline
  (on demand, cheap) / addressable retrieval (bytes, by anchor). mdnav is a working
  reference for markdown; the question is generalizing it.
- Typed MCP tool inputs give a hook an exact decision surface; shell command strings force
  regex archaeology. This is an argument for routing work through MCP tools.
- Ledger stores (decisions, entries) as additional stream kinds under Console Journal
  Contract v1 rather than a second contract.

## Deliverable

A report, under 1100 words, structured as:

A. WHAT THE IMPLEMENTATION ACTUALLY DOES vs WHAT THE CONTRACT PROMISES. Name specific
divergences, gaps, or places the code is stricter/looser than CONSOLE-CONTRACT.md.
Cite file and line. If it fully satisfies the contract, say so and move on — do not
manufacture findings.

B. NUMBERED PROPOSALS (aim for 5-8), each with: the mechanism, where it plugs in
(file/tool/hook), what it borrows from which prior project, and — required — the
round trips it removes or the reason it is worth a turn. Rank by leverage.

C. WHAT NOT TO BUILD. At least two things from the list above or from the prior projects
that look attractive but would fail here, with the reason.

D. OPEN QUESTIONS you cannot resolve from the source — things only the author knows.

Rules: cite file:line for claims about code. Flag your uncertainty explicitly rather than
smoothing it. Prefer one concrete proposal over three vague ones. Do not write any files.
