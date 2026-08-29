---
name: mdnav
description: Navigate and investigate large or numerous Markdown documents — chat exports, papers, documentation corpora — without loading them whole. Use when a document is too big to read in one pass, when working across several documents at once, when findings must cite exact source spans that stay valid as the source changes, or when you need to account for how much of a corpus you have actually read.
---

# mdnav

"Markdown navigator": a TypeScript MCP that indexes Markdown by byte span, so you
can outline, search and read a document a unit at a time instead of loading it
whole. This skill routes you into it.

## Reach for it when

- A document is large enough that reading it whole would crowd out the actual work.
- You are working across several documents and need to compare like with like.
- A finding has to cite an exact span — and stay citable after the source moves.
- You need to know what you have **not** read yet.

Skip it for a file you would read in one pass anyway. `Read` is fine there, and cheaper.

## Start here

```
mdnav_discover({ root: "./corpus" })
```

Mounts the whole corpus: every Markdown file beneath the root, indexed in one
call, addressed by coordinate, reported by relative path.

The inventory that comes back is triage. It flags documents that are mostly
embedded payload, and whether a document's `---` breaks and its `#` headings tell
the same story. Act on those notes before choosing a reading grain — the basis is
the expensive choice.

Then read **[doc-dive](D:/aghado01/science-facility/mcp/mdnav/skills/doc-dive/SKILL.md)**:
the method, the full tool reference, and the notebook discipline all live there,
with reference guides for chat archaeology, technical literature, and audit mechanics.

## Four things that catch people out

- **Content arrives framed**, with the address written out in parts —
  `D0301 : H05 @ d21b | 9 .. 60 |`, then the material, then `| D0301 : H05 @ d21b`
  to close it. Quote anchors exactly as given: the spelling is what lets separate
  mentions of one document bind to each other across a long context.
- **Addresses are coordinates.** `D0301` is group 3, document 1, so `D03xx` is one
  directory. `H05` counts headings within that document, and its width tells you
  the document's order of magnitude. `H7`, `H07` and `H0007` all resolve.
- **`read` wants a selector** — `heading`, `headings`, `from`/`to`, or `span`.
  Reading a whole document is `H00`, something you ask for by name.
- **The notebook is a tool.** `mdnav_journal_record` mints the ids, timestamps and
  lineage; an entry's status is derived from what later entries do to it.

## Where things live

| | |
|---|---|
| MCP + skills | `D:/aghado01/science-facility/mcp/mdnav` |
| Per-corpus artifacts | `<corpus>/.doc-dive/` — `journal.jsonl` at the root, reads and indices under a stamped run |
| CLI (shell work only) | `node mdnav.mjs --help` |
