---
name: mdnav
description: Navigate, investigate, and synthesize large or complex Markdown corpora (long chat exports, academic papers transferred from LaTeX/PDF, technical documentation collections) without loading them whole. Use when whole-document reads risk context saturation or when findings require byte-grounded anchors and audit trails.
---

# mdnav

`mdnav` is a structure-aware navigation MCP that indexes Markdown corpora by literal byte spans, allowing you to outline, telescope, read, and audit documents without loading them wholesale.

## doc-dive

The complete investigative loop, reading discipline, state management, and domain guides live in the canonical **`doc-dive`** skill, served by the MCP itself:

- `mdnav_skills()` — what is available, with sizes
- `mdnav_skills({ topic: "index" })` — the discipline
- `mdnav_skills({ topic, section })` / `({ topic, outline: true })` — one part of a reference
- `mdnav_skills({ search })` — find a passage across all of it

Read `index` before a first dive. It travels with the server, so it is current wherever the MCP is mounted.
