# Context hygiene

Context is scarce. Large or unbounded tool output degrades the rest of the session. Prefer paths that return findings, not raw dumps.

When output size is unknown, assume it may be large.

## Defaults

- Analysis of logs, test runs, git history, API responses, CLI listings, docs, metrics, or any tool result that might exceed a few dozen lines → process off-context and return only findings.
- File mutations, git writes, navigation, simple status checks with known-small output → direct tools are fine.
- Files you will _edit_ → normal read/edit path so you keep fidelity and control. Off-context analysis is for reading, not for preparing edits.

## Capture fully, filter later

If you truncate or narrow before the data is durable (head, early filters, “just the first N lines”), the rest is gone for this session.

- Capture complete output somewhere durable when you may need more than one pass.
- Narrow downstream, after capture.
- Do not discard evidence before you know which questions you will ask.

## Surface findings explicitly

When analysis runs off-context, only what you print enters the session.

- Always emit the findings you need: counts, IDs, paths, exact values, concrete error lines.
- Do not compute silently. No output = wasted work.
- Prefer structured summary over raw dump. Avoid printing entire objects “just in case.”

## Do not double-load

Data already present in the conversation should not be re-injected as a parameter or re-read wholesale.

- Use what is already in context when it is sufficient.
- If you need multi-pass or later search, write once to a durable location and work from that copy.
- Never pass a large prior tool result back through another tool as bulk content — that doubles cost for no gain.

## Tool and language fit

- Shell for simple pipes, native listing, and small status.
- Prefer a real language (JS/Python/etc.) once structure, parsing, or conditionals get non-trivial. Exit Bash when you are embedding `python -c`, long `jq` chains, or nested loops.
- Match timeout and environment to the work (network, builds, full test suites need more time than local file reads).

## Batch related questions

When the same corpus can answer several questions, ask them together. Avoid sequential re-reads of the same material for each question.

Prefer a few specific technical terms over vague broad queries.

## Anti-patterns

- Loading a large file into context only to answer a narrow question about it
- Truncating upstream of a durable capture so later questions cannot recover the rest
- Computing results off-context without printing them
- Re-injecting a large prior result as a tool parameter
- Staying in fragile shell for structured data work
- Treating “make it smaller” as a substitute for “return findings”

## Working signal

These guidelines are working when:

- conversation context stays focused on decisions, findings, and next actions
- large intermediate data does not appear in the session
- clarifying or follow-up questions about the same corpus do not require re-fetching everything
