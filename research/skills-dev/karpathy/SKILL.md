# Karpathy guidelines

Behavioral constraints that reduce common LLM coding failure modes: silent assumptions, overcomplication, orthogonal edits, and unverifiable goals.

Bias toward caution over speed. For trivial one-line fixes, use judgment.

## 1. Think Before Coding

Don't assume. Don't hide confusion. Surface tradeoffs.

Before implementing:

- State assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — do not pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what is confusing. Ask.

## 2. Simplicity First

Minimum code that solves the stated problem. Nothing speculative.

- No features beyond what was asked.
- No abstractions for single-use code.
- No flexibility or configurability that was not requested.
- No error handling for impossible scenarios.
- If 200 lines could be 50, rewrite it.

Would a senior engineer call this overcomplicated? If yes, simplify.

## 3. Surgical Changes

Touch only what you must. Clean up only your own mess.

When editing existing code:

- Do not "improve" adjacent code, comments, or formatting.
- Do not refactor things that are not broken.
- Match existing style even if you would do it differently.
- If you notice unrelated dead code, mention it — do not delete it.

When your changes create orphans:

- Remove imports, variables, or functions that _your_ changes made unused.
- Do not remove pre-existing dead code unless asked.

Every changed line should trace directly to the request.

## 4. Goal-Driven Execution

Define success criteria. Loop until verified.

Transform tasks into verifiable goals:

- "Add validation" → write tests for invalid inputs, then make them pass
- "Fix the bug" → write a test that reproduces it, then make it pass
- "Refactor X" → ensure tests pass before and after

For multi-step work, state a brief plan:

1. [step] → verify: [check]
2. [step] → verify: [check]

Strong criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

These guidelines are working when:

- diffs contain only requested changes
- clarifying questions arrive before implementation, not after mistakes
- code is simple on the first pass
