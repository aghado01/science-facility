# Thread Parsing & Segmentation

The `tp-perplexity.ps1` processor extracts multi-turn conversational exchanges from markdown thread exports.

## Pipeline Structure

1. **HTML Boilerplate Strip**: Removes decorative `<span>` and `<div>` artifacts.
2. **Code Block Masking**: Replaces ``` code blocks with PUA sentinel tokens to prevent internal text from matching comment or citation patterns.
3. **Citation Footer Masking**: Extracts `[^id]: ...` footer definitions into structured `Citations` arrays.
4. **Inline Citation Masking**: Protects inline `[^id]` anchor clusters in prose.
5. **Context-Disambiguated Split**: Splits exchanges on `---` horizontal rules only when preceded by citation footers or followed by an `H1` prompt.
6. **Prompt/Reply Extraction**: Isolates `H1` prompt headers and reply bodies.
7. **Sentinel Restoration**: Restores original code blocks and inline citation anchors.
