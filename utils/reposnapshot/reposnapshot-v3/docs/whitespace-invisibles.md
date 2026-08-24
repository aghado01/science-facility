# Whitespace Normalization & Invisible Code Points

The code-lane whitespace processor (`rs-whitespace.ps1`) normalizes line breaks, Unicode invisibles, and layout whitespace.

## Operation Sequence

1. `lf`: Folds all Unicode line break characters (`CRLF`, `CR`, `VT`, `FF`, `NEL`, `LS`, `PS`) to standard `LF` (`\n`).
2. `nfc`: Unicode Form C normalization.
3. `strip-zwsp`: Removes `U+200B` (Zero Width Space).
4. `strip-wj`: Removes `U+2060` (Word Joiner).
5. `strip-zwnbsp`: Removes `U+FEFF` (Zero Width Non-Breaking Space / BOM).
6. `trim-trailing`: Trims trailing whitespace from each line.
7. `trim-inner`: Collapses multi-space runs within lines (opt-in only).
8. `max-blank-1`: Collapses consecutive blank lines to at most one.
9. `trim-doc`: Trims leading and trailing document blank lines.
10. `ensure-final-lf`: Ensures the document ends with exactly one `\n`.
11. `pad-breaks`: Inserts spaces adjacent to solid characters around `\n` to isolate layout marks for wire encoding.

## Invisible Characters Policy

- **Stripped Formatting Hints**: Non-semantic presentation markers (`ZWSP`, `WJ`, `ZWNBSP`) are stripped.
- **Preserved Semantic Characters**: `U+200D` (Zero Width Joiner) and `U+200C` (Zero Width Non-Joiner) are strictly preserved because they carry linguistic meaning in Indic/Arabic/Persian scripts and compose emoji sequences.

## Receipt Honesty

The `Operations` property of the `Processing` record lists only operations that actually executed. Failed operations (e.g. ill-formed UTF-16 causing `nfc` to decline) or unrecognized operation names are recorded under `Skipped`.
