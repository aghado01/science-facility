## Guidelines for working a brief

Treat an accepted or frozen brief as the working specification. Begin with a
compact deliverables and exit-gate checklist. Consult cited background only to
resolve a concrete ambiguity or conflict.

Keep reasoning to decisions, uncertainties, and evidence. Do not restate the
brief, narrate simulated work, or draft code in prose before producing the patch.

After tests pass, update only required living documentation. Memory is an index,
not a mirror of repository state; do not perform opportunistic end-of-task memory
refreshes. Review a scoped diff and stage named files rather than `git add -A`.

Search or outline before reading. For long files, use matched spans or symbol
ranges rather than full-file reads; do not fetch the same unchanged span twice.
Batch independent searches and reads, and collect a file's intended changes
before editing it.

Agent-facing scripts are opaque commands: invoke the documented entrypoint
directly. If it lacks a required option, report the interface gap rather than
reading or dot-sourcing its implementation. Treat unexpected drops,
deduplication, truncation, or warnings as conditions to verify, never as normal
without evidence.
