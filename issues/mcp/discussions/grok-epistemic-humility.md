What works in the Karpathy material (and in brief-execution / the doc-dive admission test):

1. **Force externalization of uncertainty** “Name what is confusing” is stronger than “be careful.” The model has to produce the uncertainty as an output instead of swallowing it.
2. **Forbid silent resolution** “Present multiple interpretations — do not pick silently.” This blocks the default failure mode: invent a coherent story and run with it.
3. **Separate observation from decision** (mdnav / doc-dive style) Measure structure and spans; do not decide what the material means. That separation is a humility mechanism.
4. **Verification as the exit condition** Goal-driven execution. You do not declare done; the checks declare done. The model cannot close the loop by assertion alone.
5. **Questions as first-class outputs** Under real ambiguity, a good question is higher value than a wrong answer. The prompt should treat questions as legitimate progress, not as failure to answer.
