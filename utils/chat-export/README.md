# Chat export entrypoints

For an ordinary export, invoke the applicable wrapper directly. These commands
are the complete agent-facing contracts; reading or dot-sourcing their
implementation is unnecessary unless the user asks to debug or modify an
exporter.

```powershell
# Current Claude Code chat
& "D:\aghado01\science-facility\utils\chat-export\claude-export\Export-ClaudeChat.ps1"

# Current Codex task
& "D:\aghado01\science-facility\utils\chat-export\codex-export\Export-CodexChat.ps1"

# Current Grok session
& "D:\aghado01\science-facility\utils\chat-export\grok-export\Export-GrokChat.ps1"
```

Pass only user-requested output or exclusion overrides. Report the returned
path or paths without reading the generated transcript back into model context.

The Claude merge stage deduplicates copied continuation history by record UUID.
It retains distinct thinking, text, and tool-use records even when Claude assigns
them the same response `message.id`.

Grok post-ingest stages (live JSONL snapshot, exchange-envelope I/O, Markdown
render, run/path resolution) live in `shared/`. Claude and Codex still have
their own copies of those later stages.

Claude, Codex, and Grok Markdown output passes through the shared
`chat-export-format-ws.ps1` final-stage formatter. It normalizes line endings
and Unicode, removes zero-width formatting characters, compacts prose
whitespace, and retains significant whitespace in Markdown code and tool
payloads. Valid generated tool-call JSON is normalized recursively so escaped
invisible characters are removed without corrupting its structure; truncated
or non-JSON payloads remain literal. Canonical merged and exchange JSONL
artifacts are not modified.

Normalization is enabled by default. The ordinary agent-facing scripts expose
the boolean `-NormalizeWhitespace` option; use `-NormalizeWhitespace:$false` to
bypass only this final postprocessor and inspect the renderer's preceding
Markdown. Upstream parsing, rendering, exclusions, and truncation still apply,
so the disabled form is not a raw backend transcript. The returned result also
reports `NormalizeWhitespace`.

Markdown output defaults to BOM-less UTF-8. `-OutputEncoding Utf16LE` is an
opt-in alternative on the wrappers, runners, and standalone renderers. It
writes an `FF FE` BOM followed by every rendered .NET UTF-16 code unit verbatim,
including an isolated surrogate if one survived upstream parsing. Canonical
snapshot, merged, and exchange JSONL remain UTF-8.

## Frozen-master forensic pair

Do not invoke an ordinary renderer twice when the files need a strict diff:
frontmatter includes a fresh `exported_at` value on each render. Use the special
agent-facing wrapper instead:

```powershell
& "D:\aghado01\science-facility\utils\chat-export\Export-ChatWhitespacePair.ps1" `
    -Provider Codex

& "D:\aghado01\science-facility\utils\chat-export\Export-ChatWhitespacePair.ps1" `
    -Provider Claude `
    -OutputEncoding Utf16LE

& "D:\aghado01\science-facility\utils\chat-export\Export-ChatWhitespacePair.ps1" `
    -Provider Grok
```

The wrapper freezes the provider source once through the exchange-envelope
stage, renders one pre-normalization Markdown master, and computes the sibling
as exactly `Format-ChatExportMarkdown(master)`. It never performs a second
render. Both files use the same selected encoding, so timestamp drift, source
growth, and independent rendering cannot contaminate the diff. The returned
object includes source and exchange hashes, both output hashes and byte lengths,
the paths, encoding, `RenderCount = 1`, and the enforced pair invariant.

Forensic defaults intentionally differ from ordinary archival defaults:
`-Exclude @()` retains every supported block and `-MaxToolInputLength $null`
disables tool-input truncation. Intermediate freezes default to the caller's
workspace-local `.codex/chat-export` directory. Output defaults to
`$env:JSO_EXPORT_DIR`, then `D:\aghado01\.discussion`.

`Utf16LE` preserves the final renderer's UTF-16 code units; it does not recover
original backend bytes or transformations already performed while decoding and
parsing JSONL. Use the returned frozen JSONL paths and hashes when that earlier
evidence boundary matters.

Regression checks:

```powershell
& "D:\aghado01\science-facility\utils\chat-export\tests\claude-export.tests.ps1"
& "D:\aghado01\science-facility\utils\chat-export\tests\grok-export.tests.ps1"
& "D:\aghado01\science-facility\utils\chat-export\tests\markdown-whitespace.tests.ps1"
& "D:\aghado01\science-facility\utils\chat-export\tests\forensic-pair.tests.ps1"
```
