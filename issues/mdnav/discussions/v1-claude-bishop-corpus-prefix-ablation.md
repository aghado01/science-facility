That reframes it usefully — you already *have* the confusable corpus, so the constraint is instrumentation, not fixtures. Let me look at the testbed you're pointing at.

MCP has restarted — 12 tools live, with `newRun`, per-species `strip`, and `run` all present. Let me look at the corpus.

Good testbed — better than a synthesized one, for a reason that isn't obvious until you look:

**Bishop has intrinsic ground truth.** Section numbers are *in the heading text* (`3.5.1 Evaluation of the evidence function`), and the book numbers its equations too. You don't need to plant facts — "which section defines the evidence approximation" already has one right answer, mechanically checkable against the anchor cited.

**And the confusability is graded, not binary.** Ch3 Linear Regression / Ch4 Linear Classification are structurally parallel with shared vocabulary; Ch6/Ch7 (Kernel / Sparse Kernel); Ch9/Ch10 (EM / Approximate Inference) — while Ch2 vs Ch13 are distant. So you can measure misattribution *as a function of source similarity* instead of getting one undifferentiated rate. That's a much more informative curve, and it's the thing a synthetic corpus is hardest to give you.

Scale is right: 1.77 MB ≈ 450k tokens, well past any single window. Clean too — no embedded payloads, no signed URLs, just CRLF, so no noise confound. Working grain is depth 2. One wrinkle: leveling is slightly irregular (3.3.1/3.3.2 sit at H3 while 3.3.3 is at H2), so depth-2 outlines have small gaps.

## On the instrumentation

`MDNAV_PREFIX=off` is already the right *mechanism* — env-level, so tool schemas and descriptions stay byte-identical across arms. That matters more than it looks, because **tool descriptions are in the context stream too**; a per-call parameter would leak the manipulation into the instructions.

Two gaps before it's usable:

1. **It's incomplete** — `batch_read` still emits its comment tag with prefixes off (verified earlier).
2. **It confounds two variables.** On/off simultaneously changes *whether provenance is present* and *whether it's decomposed*. Those are different claims — presence is probably the large effect, decomposition is the subtle tokenization one. With a binary switch you can't attribute the result to either.

What I'd build instead — named levels, still env-driven so nothing in-context changes:

| | emits |
|---|---|
| `full` (default) | `D004 : H0014 @ a775 \| 8420 .. 9860 \|` + close |
| `fused` | `D004:H0014@a775 \| 8420 .. 9860 \|` + close — isolates decomposition |
| `open` | full frame, no close — isolates the terminator |
| `none` | bare content |

Four arms, one variable at a time.
