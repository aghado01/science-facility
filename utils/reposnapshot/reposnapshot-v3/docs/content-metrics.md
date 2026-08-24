# Content Metrics & Statistics

The `rs-content_meta.ps1` processor computes character, word, and information-theoretic metrics over processed string contents.

## Metrics Model

- **`SpanBytes`**: Exact UTF-8 byte count of the processed payload string in memory.
- **`CharCount`**: Total string length in characters (.NET `String.Length`).
- **`WordCount`**: Naive `\s+` split count.
- **`PunctuationCount`**: Regex `\p{P}` match count.
- **`UniqueChars`**: Number of distinct character values.
- **`Entropy`**: Shannon entropy per character:
  $$H = -\sum p_i \log_2(p_i)$$
- **`CompressionRatio`**: Kolmogorov complexity proxy using in-memory `GZipStream` over UTF-8 bytes (evaluated on strings $>100$ characters).
- **`WhitespaceRatio`**: Fraction of characters matching `\s`.
- **`LineStats`**: Line length statistics (`Mean`, `Median`, `StdDev`, `Max`).

## Byte Semantics & Invariants

- Metrics are computed on the **processed** content, capturing transformations applied by earlier mutators.
- All byte measurements are calculated in UTF-8 by invariant convention, independent of serializer encoding options.
