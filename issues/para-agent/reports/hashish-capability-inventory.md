# Hashish capability and application inventory

**Status:** conceptual inventory; no implementation authorized | **Date:** 2026-08-10

**Scope:** the 22 C# files in [`ThermoMapper/src/hashish`](../../../../ThermoMapper/src/hashish), treated as a toolbox of representations, measures, signatures, search models, and streaming summaries rather than as an API or MCP-tool proposal

## Executive orientation

Hashish is not one hashing library. It is a compact survey of several different computational questions that happen to use hashing, compact representations, or pairwise comparison:

1. How should text become stable comparable features?
2. How similar are two sequences, sets, vectors, or compressible byte strings?
3. Can a compact signature cheaply nominate likely-similar items?
4. Can a corpus model retrieve relevant documents or reveal contextual associations?
5. Can a bounded streaming structure answer membership, frequency, or cardinality questions approximately?

The word “hash” hides an important distinction. The current module contains **no cryptographic content digest**: no SHA, BLAKE, or equivalent exact-identity primitive. [`seeded.cs`](../../../../ThermoMapper/src/hashish/seeded.cs) provides non-cryptographic FNV-derived hashing and mixing for buckets and sketches. SimHash, MinHash, CTPH, and TLSH are resemblance fingerprints. Bloom, Count-Min, and HyperLogLog are probabilistic summaries. None can authoritatively identify an artifact.

That absence is useful design information. A complete system needs a separate cryptographic digest for byte identity and integrity, then may use Hashish-derived capabilities for search, candidate generation, comparison, ranking, diversity, and telemetry.

The conceptual value of the module is therefore not “many kinds of IDs.” It is a palette of different summaries over different representations. Choosing the representation is usually more important than choosing the final formula.

## Quick question-to-capability map

| Question | Best-matching concept in Hashish | Result | Typical use |
|---|---|---|---|
| Are these exact bytes the same? | **Not present**; use a sibling cryptographic digest | Exact content identity | Integrity, exact deduplication, source guards |
| How many character edits separate these strings? | Levenshtein | Exact edit count or normalized score | Typos, renamed symbols, recurring error variants |
| What fraction of unique features is shared? | Jaccard | Exact set-overlap score | Tags, shingles, dependency sets, exact verification of MinHash candidates |
| Is a small query contained in a larger candidate? | Containment or overlap coefficient | Exact asymmetric or smaller-set-normalized overlap | Snippet reuse, inclusion, partial-copy detection |
| Do two weighted profiles point in the same direction? | Cosine | Exact vector similarity/angular distance | TF-IDF documents, PPMI token contexts, frequency profiles |
| Do two items share compressor-detectable structure without a feature model? | Normalized Compression Distance | Heuristic pairwise distance | Small-scale heterogeneous text/binary comparison, outlier exploration |
| Are two weighted bags of words probably near-duplicates? | SimHash | 64-bit signature plus Hamming distance | Fast near-duplicate screening, clustering, novelty candidates |
| Do two character-shingle sets probably overlap? | MinHash | Approximate Jaccard signature | Web/document deduplication, version-family discovery |
| Which MinHash signatures are plausible neighbors? | Banded LSH | Candidate IDs | Sublinear shortlist before exact comparison |
| Did local insertions/deletions preserve much of a file? | CTPH concept | Piecewise fuzzy digest | Evolving-file family detection; current implementation is only a concept donor |
| Are two sufficiently large contents locally/distributionally alike? | TLSH concept | Locality-sensitive digest and distance | Binary/sample family clustering; current implementation is not established TLSH |
| Which terms are specific to this corpus? | IDF | Per-token corpus weights | Search weighting, stop/common-term suppression, fitted signatures |
| Which documents are lexically relevant to a query? | TF-IDF plus cosine/top-K | Ranked document IDs and scores | Local search, context selection, related-document discovery |
| Which words occur in characteristic neighboring contexts? | Co-occurrence plus PMI/PPMI | Association scores and context vectors | Terminology exploration, semantic neighbors, corpus archaeology |
| Is a token contextually broad or specific? | Contextual entropy | Entropy in bits or normalized score | Generic-term detection, ambiguity/breadth signals, vocabulary diagnostics |
| Has this exact key probably been inserted? | Bloom filter | Definitely absent or possibly present | Negative cache, duplicate-ingress prefilter, expensive-lookup avoidance |
| Approximately how often has this key occurred? | Count-Min Sketch | Upper-biased frequency estimate | Heavy hitters, repeated-event telemetry, bounded frequency tracking |
| Approximately how many distinct keys occurred? | HyperLogLog | Cardinality estimate | Unique artifacts, commands, errors, actors, or sessions at scale |

## The four meanings of “hash” in this module

### 1. Authoritative content identity — absent

A cryptographic digest answers an equality/integrity question over exact bytes. Hashish does not implement one. This role should be supplied by a separate SHA-256 or equivalent service and kept distinct from every result below.

### 2. Deterministic addressing and hash-family substrate

[`SeededHash`](../../../../ThermoMapper/src/hashish/seeded.cs) supplies a 64-bit mixer and seeded FNV-1a paths over UTF-16 code units, bytes, and `uint` sequences. Its value is fast, repeatable distribution into buckets and the derivation of several pseudo-independent hash positions.

Useful applications include:

- Bloom-filter bit positions;
- Count-Min rows;
- MinHash LSH band keys;
- deterministic partitions or in-memory hash tables;
- reproducible test fixtures when the input basis and seed are fixed.

It is not collision-resistant, adversarially safe, or suitable as durable artifact identity. Its three overloads hash materially different representations, so persisted use would need an explicit input-basis and algorithm version.

### 3. Locality-sensitive or fuzzy fingerprints

SimHash, MinHash, CTPH, and TLSH intentionally make similar inputs more likely to have nearby or partially matching signatures. A collision or small distance is evidence for a candidate comparison, not equality.

### 4. Hash-backed probabilistic summaries

Bloom, Count-Min, and HyperLogLog trade exact per-key state for fixed or sublinear memory. Their outputs have false-positive or error semantics, not identity semantics.

## Representation and feature construction

These files are foundational because every downstream similarity claim is relative to a representation.

### Normalization and word tokenization

[`tokenizer.cs`](../../../../ThermoMapper/src/hashish/tokenizer.cs) provides Unicode normalization, optional compatibility folding, invariant lowercasing, trimming, and `\w+` word extraction with a minimum token length.

Conceptual value:

- makes text features reproducible rather than dependent on incidental casing or Unicode forms;
- supplies a shared representation to IDF, TF-IDF, shingling, and co-occurrence analysis;
- makes model/profile identity explicit: changing normalization or tokenization changes every downstream result.

Potential applications include prose, logs, identifiers, command output, and metadata fields. The representation discards punctuation, whitespace shape, and operator structure, so it is not automatically appropriate for source code, diffs, paths, or exact shell syntax. Compatibility normalization can deliberately collapse visually or semantically related Unicode forms while also erasing distinctions a fidelity-sensitive consumer may care about.

### Word shingles

[`shingler.cs`](../../../../ThermoMapper/src/hashish/shingler.cs) turns token streams into ordered word n-grams, either preserving duplicate shingles or returning a set.

Shingles reintroduce **local order** after tokenization. A unigram set knows that two documents use the same words; a two- or three-word shingle set also knows which short phrases survived.

Useful applications include:

- near-duplicate prose detection;
- phrase and passage overlap;
- containment of a short excerpt in a longer document;
- distinguishing documents that share vocabulary but arrange it differently;
- exact verification after a coarser candidate screen.

Width is a semantic knob. Small widths tolerate edits and rearrangement but create more accidental matches; large widths are more specific but brittle. Converting to a set discards repeated occurrence counts.

### Histograms and smoothed probability distributions

[`histogram.cs`](../../../../ThermoMapper/src/hashish/histogram.cs) converts counts into a probability mass function and can build a unigram distribution against a shared vocabulary. Lidstone smoothing includes unsmoothed, Jeffreys-like, and Laplace-style choices.

The histogram is not itself a similarity measure. It is a representation for distributional comparisons such as KL/JS divergence, Hellinger distance, Fisher–Rao geometry, or simple drift statistics; those measures are outside this directory.

Useful applications include:

- comparing token or event-type distributions across runs;
- measuring vocabulary drift across time or projects;
- characterizing agents, tools, repositories, or error populations by relative frequency;
- feeding downstream information-theoretic or clustering methods.

Smoothing changes the meaning of zero and must be part of the comparison profile.

## Exact and heuristic pairwise measures

There is no universal similarity. These measures answer different questions even when all return a number near zero or one.

### Levenshtein: sequence edit effort

[`levenshtein.cs`](../../../../ThermoMapper/src/hashish/levenshtein.cs) computes the exact minimum number of insertions, deletions, and substitutions between two character sequences, plus a length-normalized similarity.

Useful for:

- misspellings and fuzzy names;
- command-line or error-message variants;
- small source fragments and renamed symbols;
- matching paths or identifiers after limited edits;
- verifying candidate strings from a cheaper prefix, n-gram, or hash lookup.

It retains sequence order but treats each UTF-16 code unit uniformly and has quadratic time in the general case. It is strongest on short or already-shortlisted inputs, not as an all-pairs long-document search primitive. It reports edit cost, not semantic equivalence and not an edit script.

### Jaccard: shared unique-feature proportion

[`jaccard.cs`](../../../../ThermoMapper/src/hashish/jaccard.cs) implements exact Jaccard similarity and distance over sets:

```text
|A ∩ B| / |A ∪ B|
```

It is useful whenever features are naturally present/absent rather than counted:

- token or shingle sets;
- dependency, tag, file, API, or diagnostic-code sets;
- exact calibration and verification for MinHash;
- duplicate-family clustering.

Jaccard ignores order and multiplicity. Its meaning depends completely on feature construction: Jaccard over words, word shingles, character shingles, paths, and AST features are different measures.

### Containment: asymmetric coverage

The same file implements:

```text
|query ∩ candidate| / |query|
```

Containment answers “how much of the query appears in the candidate?” rather than “how mutually similar are these sets?” This makes it especially useful for:

- a short excerpt inside a long report;
- copied code or configuration inside a larger file;
- whether a result covers the requested concepts;
- checking whether a newer artifact preserves a required feature set.

Direction matters. Reversing query and candidate asks a different question.

### Overlap coefficient: smaller-set coverage

The overlap coefficient divides the intersection by the size of the smaller set. It reaches one when either set is wholly contained in the other, without requiring the caller to choose a direction.

It is useful for subset-family detection and comparing items with very different sizes. It can overstate general similarity when a tiny set happens to sit inside a large one, so the underlying sizes should accompany the score.

### Sørensen–Dice: overlap-emphasized set score

Dice uses `2|A ∩ B| / (|A| + |B|)`. It gives shared elements more weight than Jaccard and is often intuitive for sparse labels, segmentation masks, n-grams, and short documents.

For the same two sets, Dice is a monotonic transform of Jaccard, so it does not produce an independent ranking. Its value is interpretation and threshold calibration, not a second source of evidence.

### Cosine: direction of a weighted profile

[`cos.cs`](../../../../ThermoMapper/src/hashish/cos.cs) provides cosine similarity, angular distance, in-place L2 normalization, and pairwise distance-matrix construction.

Cosine asks whether two vectors have similar **relative feature emphasis**, largely ignoring total magnitude. It becomes useful after a representation such as:

- TF-IDF document vectors;
- PPMI context vectors;
- token/event histograms;
- tool-usage or diagnostic-frequency profiles;
- any shared numeric feature space.

Cosine does not know what a dimension means, and scores across different vocabularies or fitted models are incomparable. The current zero-vector convention is internally inconsistent: the comment promises maximum distance, while the implementation yields angular distance `0.5`. That contract needs correction before the value is treated as authoritative.

### Normalized Compression Distance: shared compressible structure

[`ncd.cs`](../../../../ThermoMapper/src/hashish/ncd.cs) compares the compressed sizes of `x`, `y`, and their concatenation using Brotli, Deflate, GZip, or ZLib.

Its conceptual appeal is feature agnosticism: if a compressor can reuse patterns from one input while compressing the other, the pair probably shares structure. This can reveal resemblance in raw text, serialized data, or binaries without first designing tokens.

The exposed compressed-size operation is also independently useful as a codec-specific redundancy or storage-planning signal. It answers “how compressible is this representation under this codec and configuration?”, which is a different question from pairwise resemblance and still does not identify the content.

Useful applications include:

- exploratory clustering of small heterogeneous collections;
- comparing artifacts when no satisfactory feature model exists;
- anomaly or outlier nomination;
- a sanity-check against representation-specific measures.

It is expensive for search because every pair requires compression, sensitive to codec and concatenation order, distorted by small-input headers, and not guaranteed to remain inside `[0,1]` for finite real compressors. It is heuristic resemblance, not identity.

### Common measure interface

[`measure.cs`](../../../../ThermoMapper/src/hashish/measure.cs) wraps Levenshtein, cosine, Jaccard, and Dice behind `Distance` and `Similarity` methods.

The conceptual value is generic pairwise orchestration: clustering, matrix construction, or evaluation code can accept a measure without naming the algorithm. The danger is false interchangeability. A Levenshtein distance, angular distance, and Jaccard distance have different domains and calibration; a common method name does not make thresholds portable across them. The current abstraction has no in-tree consumer.

## Compact similarity signatures and candidate search

These capabilities exchange information for speed. Their best use is to reduce a large search space, then retain an exact or richer verifier.

### SimHash: compact angular resemblance

[`simhash.cs`](../../../../ThermoMapper/src/hashish/simhash.cs) builds a 64-bit signature by hashing features, adding or subtracting their weights in each bit dimension, and taking the sign of the accumulated vector. Hamming distance between signatures is the comparison.

Conceptually, SimHash is a compact proxy for cosine/angular similarity over weighted features. Hashish uses case-folded word tokens with BM25-style term-frequency saturation and fitted IDF weights.

Useful applications include:

- near-duplicate document or output screening;
- cheap clustering/bucketing before a richer comparison;
- diversity selection and novelty nomination;
- detecting repeated results with small lexical changes;
- retaining a tiny per-artifact resemblance signature.

Its current representation is a bag of words, so token order is lost. Corpus/model identity matters because changing IDF changes the signature. Most importantly, the default empty IDF map plus `unknownIdf = 0` assigns every token zero weight, so the zero-setup instance collapses every input to signature `0`. A corrected explicit profile or fitted model is required.

### MinHash: compact set-overlap estimation

[`minhash.cs`](../../../../ThermoMapper/src/hashish/minhash.cs) builds a signature from a set of character n-grams. The fraction of equal signature slots estimates Jaccard similarity.

MinHash is appropriate when the desired notion of resemblance is shared set membership, especially:

- character-shingle overlap across edited documents;
- duplicate web pages or records;
- version-family discovery;
- large-scale set similarity where exact intersections are too costly for every pair.

Unlike SimHash, it estimates Jaccard rather than angular similarity. The current implementation uses raw character shingles without the shared normalization pipeline. Inputs shorter than the shingle width produce all-`uint.MaxValue` signatures, so two unrelated short inputs estimate as perfectly similar. Signature length, shingle width, input normalization, and hash family are part of result identity.

### Banded LSH: turning signatures into candidate IDs

The second half of [`minhash.cs`](../../../../ThermoMapper/src/hashish/minhash.cs) divides signatures into bands and indexes exact band matches. A query returns document IDs sharing at least one band.

This is a search accelerator, not another similarity measure. Band count and rows per band determine the probability curve: more bands improve recall but produce more candidates; more rows per band improve precision but miss more marginal matches.

For estimated Jaccard similarity `s`, `b` bands, and `r` rows per band, the usual candidate probability is `1 - (1 - s^r)^b`. Hashish's default `32 × 4` arrangement crosses roughly 50% candidate probability near `s = 0.38`; that is a tunable probability curve, not a similarity threshold or guarantee.

The canonical pipeline is:

```text
feature set → MinHash signature → LSH candidates → exact Jaccard/containment verification
```

The LSH result means “worth comparing,” not “duplicate.”

### CTPH: local-edit-resilient piecewise fingerprinting

[`ctph.cs`](../../../../ThermoMapper/src/hashish/ctph.cs) gestures at ssdeep-style context-triggered piecewise hashing: choose content-dependent boundaries, hash chunks at two resolutions, and compare the resulting digest sequences.

The underlying concept is valuable for files where insertions or deletions shift byte offsets but much local content survives. Potential applications include:

- version-family and derivative-file detection;
- triaging generated artifacts with localized changes;
- finding common regions across evolving binary or text files;
- malware/sample or forensic resemblance screening.

The current implementation is not a true rolling-window CDC or established ssdeep implementation. Its trigger is a cumulative FNV prefix that never evicts old symbols, its digest reinterprets native-endian `ulong` bytes, and truncating the Base64-encoded sequence to 64 characters preserves only the first six complete `ulong` chunk hashes. Its comparison/block rules also need oracle tests. It should be treated as a conceptual donor or explicitly named project variant, not an interoperable CTPH result.

### TLSH: whole-content locality-sensitive fingerprinting

[`tlsh.cs`](../../../../ThermoMapper/src/hashish/tlsh.cs) builds a sliding-window bucket histogram, quartile-encodes the bucket distribution, and combines it with length and checksum information.

The TLSH concept is useful for sufficiently large, varied inputs where a whole-content fuzzy fingerprint can cluster related binaries or documents while tolerating moderate change. It is commonly more appropriate for family resemblance than for tiny strings or highly repetitive low-entropy material.

Hashish's implementation is TLSH-shaped rather than established TLSH: it hashes only the low byte of UTF-16 code units in the bucket path, uses UTF-8 for the checksum, and compares body hex characters with a simplified mismatch count. Conform to published vectors or rename it before interoperability or threshold claims.

## Corpus weighting, retrieval, and distributional semantics

### IDF: corpus-specific feature salience

[`idf.cs`](../../../../ThermoMapper/src/hashish/idf.cs) calculates document frequencies, average document length, and inverse-document-frequency weights using smooth, Robertson–Sparck Jones, or plain formulas.

IDF expresses a simple valuable idea: a term appearing in every document carries less discriminating information than a rare term. It is useful for:

- lexical search and document ranking;
- downweighting boilerplate or ubiquitous diagnostics;
- identifying corpus-specific vocabulary;
- weighting SimHash or other feature summaries;
- feature selection and explanation.

An IDF value is not an intrinsic property of a word. It belongs to a corpus generation, tokenization profile, formula, and scope. A project-local model and global model answer different questions.

### BM25 statistics shim: fitted weights for SimHash, not BM25 search

[`bm25.cs`](../../../../ThermoMapper/src/hashish/bm25.cs) returns average document length and a smoothed IDF map in the tuple expected by SimHash. SimHash then uses BM25-style term-frequency saturation and document-length normalization in its feature weights.

The conceptual pieces—term saturation, length normalization, and corpus rarity—are valuable. The current file is explicitly a legacy compatibility shim; it does **not** implement a BM25 document-retrieval scorer or inverted index. Calling Hashish's retrieval “BM25” would overstate the capability.

### TF-IDF vectorization

[`tfidf.cs`](../../../../ThermoMapper/src/hashish/tfidf.cs) provides:

- a reusable tokenized corpus;
- corpus fitting and vocabulary pruning;
- raw or sublinear term frequency;
- three IDF formulas;
- dense and per-document sparse transforms;
- optional L2 normalization;
- deterministic vocabulary-column order;
- parallel batch transformation.

TF-IDF is a strong local, explainable baseline for:

- query-to-document relevance;
- related-document and related-output discovery;
- clustering and map/layout inputs;
- context-pack candidate ranking;
- lexical diversity or redundancy checks;
- diagnosing which terms made two documents appear related.

It is lexical rather than semantic: synonyms with no token overlap remain far apart, and shared boilerplate can dominate if pruning/model scope is poor. The fitted vocabulary and IDF model must travel with every vector.

### TF-IDF search

[`tfidf_search.cs`](../../../../ThermoMapper/src/hashish/tfidf_search.cs) scores a sparse query against dense document rows and provides nearest-document lookup with a bounded `O(N log K)` top-K heap.

This is an actual retrieval capability, although it is a full scan rather than an inverted or approximate-nearest-neighbor index. It is most attractive for small-to-medium local corpora where simplicity, explainability, and no external service are more valuable than internet-scale indexing.

The current scorer is cosine only when model rows are L2-normalized; with normalization disabled it still uses dot products while calling them cosine. It also needs an explicit zero-dimensional-model path and deterministic equal-score ties.

### Co-occurrence model

[`cooc.cs`](../../../../ThermoMapper/src/hashish/cooc.cs) builds a vocabulary and dense symmetric matrix of token co-occurrences within a sliding context window.

Where TF-IDF represents documents by the terms they contain, co-occurrence represents terms by the neighbors they keep. This enables distributional questions such as:

- which technical terms appear in similar contexts;
- what vocabulary is associated with a subsystem or failure mode;
- whether a word's usage changes between corpora;
- which terms may serve related roles even if they rarely occur in the same document;
- corpus exploration and terminology archaeology.

Window size defines “context.” Small windows emphasize syntactic/local relations; larger windows become more topical. The dense `V²` matrix makes this a bounded-vocabulary capability, not a default for unbounded logs. The current symmetric traversal appears to double every pair and marginal; some normalized statistics cancel the factor, but raw counts, work, and overflow do not.

### PMI, PPMI, conditional probability, and contextual entropy

[`cooc_stats.cs`](../../../../ThermoMapper/src/hashish/cooc_stats.cs) derives several different signals:

| Statistic | Meaning | Useful application |
|---|---|---|
| PMI | How much more or less often two tokens co-occur than independence predicts | Strong association discovery; rare-pair inspection |
| PPMI | PMI with negative values clamped to zero | Nonnegative distributional vectors; semantic-neighbor search |
| Conditional probability | Probability of context token `b` given token `a` | Directed association and likely-context queries |
| PPMI vector | A token represented by all its positive context associations | Cosine similarity, clustering, visualization |
| Contextual entropy | Diversity of a token's context distribution | Broad/generic versus narrow/specific usage; ambiguity signal |
| Top context neighbors | Highest-PPMI tokens for one token | Model inspection, terminology discovery, cluster labeling |

PMI tends to overvalue rare coincidences without frequency thresholds or smoothing. Contextual entropy is affected by corpus size, pruning, window choice, and frequency; it is evidence of breadth, not proof of semantic ambiguity.

## Streaming and probabilistic data structures

### Bloom filter: bounded membership memory

[`bloom.cs`](../../../../ThermoMapper/src/hashish/bloom.cs) sizes a bit array from expected item count and desired false-positive probability, uses double hashing, tracks insertions, and reports fill ratio.

Semantics:

- `false` means definitely not inserted, assuming a complete and compatible filter generation;
- `true` means possibly inserted and requires exact verification for an authoritative claim;
- ordinary Bloom filters do not support safe deletion.

Useful applications include avoiding expensive exact lookups for definitely-new keys, screening previously processed artifact IDs, cache admission, and duplicate-ingress prefilters. It is not a similarity index and cannot return candidate IDs.

### Count-Min Sketch: bounded approximate frequency

[`countmin.cs`](../../../../ThermoMapper/src/hashish/countmin.cs) maintains several hashed counter rows and estimates a key's count as the minimum observed counter.

With positive updates and suitable hash assumptions, collisions make the estimate overcount rather than undercount. Width controls additive error; depth controls the probability of exceeding that error.

Useful applications include:

- recurring command, error, token, or event estimates;
- heavy-hitter nomination;
- adaptive sampling or promotion candidates;
- detecting sudden frequency changes under a bounded memory budget.

It does not enumerate keys on its own, so heavy-hitter discovery still needs a candidate source. The current implementation has no merge, serialization, conservative-update, overflow, or concurrency contract.

### HyperLogLog: bounded approximate distinct count

[`hyperloglog.cs`](../../../../ThermoMapper/src/hashish/hyperloglog.cs) distributes hashes into registers, records leading-zero ranks, estimates cardinality, applies a small-range correction, and can merge states with matching precision.

Its relative standard error is approximately `1.04 / sqrt(registerCount)` under the usual assumptions. It is useful when the question is “how many unique?” rather than “which ones?”

At Hashish's default precision `p = 14`, the sketch uses 16,384 one-byte registers—about 16 KiB of raw register storage—for a nominal relative standard error of about 0.81%. Precision therefore makes the memory/error tradeoff explicit.

Applications include distinct artifacts, commands, failures, sessions, paths, or users over large streams; comparing activity breadth across windows; and mergeable per-worker telemetry. HLL cannot enumerate members and must not provide exact billing, receipt, or lifecycle counts.

## Useful compositions

The main value of the grab bag appears when complementary capabilities are composed while their authority remains separate.

### Exact artifact identity plus resemblance

```text
captured bytes
  → cryptographic digest (external to Hashish): exact identity/integrity
  → versioned derived view
  → similarity signature: candidate nomination
  → exact representation measure: candidate verification
```

This preserves the distinction between “same bytes,” “same normalized view,” and “similar under one representation.”

### Scalable set-similarity search

```text
content → character or word shingles → MinHash → LSH shortlist
                                             → exact Jaccard/containment
```

Useful for document families, copied passages, result redundancy, and large near-duplicate collections.

### Lexical search and related-document discovery

```text
corpus → tokenizer → IDF/TF-IDF model → document vectors
query  → same model → sparse query vector → top-K dot/cosine scores
```

Useful for local artifact search, evidence selection, related outputs, and explainable context ranking.

### Distributional terminology exploration

```text
corpus → tokenizer → windowed co-occurrence → PPMI vectors
                                             → cosine neighbors / clustering
                                             → contextual entropy
```

Useful for learning a project's vocabulary, finding related technical concepts, inspecting semantic drift, and labeling clusters.

### Streaming telemetry under bounded memory

```text
exact-key stream
  ├─ Bloom: have I possibly seen this key?
  ├─ Count-Min: about how often have I seen it?
  └─ HyperLogLog: about how many different keys have I seen?
```

These structures answer complementary questions and cannot substitute for one another.

### Fuzzy file-family screening

```text
large content → validated CTPH/TLSH-like signature → candidate family
                                                   → richer comparison
                                                   → exact byte digest if equality matters
```

The concept is valuable, but Hashish's current CTPH and TLSH implementations need conformance or explicit project-variant names first.

## Application palette for para-agent and adjacent tooling

These are possible uses of the concepts, not commitments to implement them:

| Application | Candidate capability mix | Why it may help |
|---|---|---|
| Exact output reuse or source guarding | External SHA-256 | Proves exact captured bytes, unlike fuzzy signatures |
| Repeated-output family detection | SimHash or MinHash candidates, then exact comparison | Groups small lexical variants without suppressing evidence automatically |
| Snippet/report inclusion | Word-shingle containment | Measures whether requested or prior material is covered inside a larger result |
| Similar error normalization | Levenshtein, token/shingle Jaccard | Groups IDs, paths, and numbers changing inside otherwise recurring messages |
| Local artifact search | TF-IDF top-K with bounded materialization | Explainable, dependency-light lexical retrieval |
| Context diversity selection | TF-IDF/cosine or MinHash/Jaccard | Avoids returning several nearly identical candidates under a real byte budget |
| Project vocabulary archaeology | Co-occurrence, PPMI neighbors, contextual entropy | Reveals terms used together and generic versus specialized language |
| Loop/thrashing observation | Exact occurrence sequence plus optional similarity evidence | Distinguishes repeated targeting from genuinely repeated content; remains advisory |
| High-volume event telemetry | Count-Min plus an external candidate/key registry | Estimates repeated events without retaining every count |
| Unique-workload telemetry | HyperLogLog | Estimates breadth without storing all identities |
| Negative cache for derived projections | Bloom plus exact store lookup | Avoids expensive checks when an exact key is definitely absent |
| Artifact/version-family exploration | Validated fuzzy digest or MinHash/LSH | Finds likely relatives before exact or semantic inspection |

The general rule is to expose the semantic product—related artifacts, coverage, ranked evidence, approximate workload breadth—not the internal algorithm sequence.

## Capabilities that Hashish does not currently provide

The inventory should not turn conceptual adjacency into an implementation claim. The directory does not contain:

- a cryptographic content digest or exact artifact-identity contract;
- a true reusable content-defined chunker/chunk manifest with cryptographic chunk IDs;
- a full BM25 retrieval scorer or inverted index;
- a persistent sparse corpus index or approximate vector-neighbor index;
- learned embeddings or semantic models beyond count-based distributional representations;
- versioned serialization formats for models, signatures, Bloom, Count-Min, HLL, or LSH;
- production conformance vectors, calibration corpora, or benchmarks;
- general merge semantics for most fitted and streaming structures;
- authority to suppress, delete, promote, or govern evidence based on a similarity or estimate.

## Donor implementation maturity

The direct source is a broad prototype and conceptual quarry, not a certified suite. The existing [`ThermoMapper hashish review`](../../../../ThermoMapper/issues/doccer-excavation-hpc-hashish-review-20260806.md) explicitly reports no benchmark or compatibility testing.

| Readiness band | Components | Interpretation |
|---|---|---|
| Strong implementation shape, still needs oracle tests | Levenshtein; exact Jaccard/containment/Dice; IDF; tokenizer; core TF-IDF paths | Concepts and implementation structure are credible, but no donor test suite establishes a compatibility contract |
| Useful with a corrected explicit contract | Cosine; histogram; TF-IDF search; co-occurrence/stats; Bloom; Count-Min; HyperLogLog; common measure interface | Valuable capability, with edge cases, mutability, error, scaling, or unused-abstraction questions to settle |
| Valuable candidate machinery with profile/calibration work | SimHash; MinHash; LSH | Keep preprocessing/model/signature identity explicit; fix default/short-input cases and validate recall/error behavior |
| Concept donor or project-specific variant | CTPH; TLSH | Do not claim standard compatibility; either conform and test or rename |
| Heuristic exploratory measure | NCD | Useful in bounded pairwise exploration; codec/order/finite-size behavior is part of the result |
| Internal substrate only | Seeded FNV/mixer; BM25 tuple shim | Supports other capabilities; not a durable identity or standalone product |

Particularly important current caveats are:

1. default SimHash collapses all inputs to zero because unknown tokens receive zero weight;
2. two MinHash inputs shorter than the shingle width appear perfectly similar;
3. cosine's zero-vector distance contradicts its documentation;
4. TF-IDF search calls an unnormalized dot product cosine when L2 normalization is disabled and fails to handle a zero-dimensional model;
5. co-occurrence appears to double symmetric pair counts and uses dense quadratic storage;
6. CTPH is cumulative-prefix-triggered rather than a true rolling-window CDC implementation;
7. TLSH comparison and byte treatment are simplified and not shown compatible with TLSH;
8. all persisted or compared results need algorithm, representation, parameters, model, and source identity.

## Complete source-to-capability coverage

| Source file | Embedded capability | Conceptual home |
|---|---|---|
| [`seeded.cs`](../../../../ThermoMapper/src/hashish/seeded.cs) | 64-bit mixer and seeded FNV over chars, bytes, and `uint`s | Hash-family substrate |
| [`bloom.cs`](../../../../ThermoMapper/src/hashish/bloom.cs) | Sized Bloom filter, double hashing, membership, fill ratio | Probabilistic membership |
| [`countmin.cs`](../../../../ThermoMapper/src/hashish/countmin.cs) | Epsilon/delta-sized Count-Min Sketch | Approximate streaming frequency |
| [`hyperloglog.cs`](../../../../ThermoMapper/src/hashish/hyperloglog.cs) | Precision-sized HLL, estimate, merge | Approximate distinct cardinality |
| [`minhash.cs`](../../../../ThermoMapper/src/hashish/minhash.cs) | Character-shingle MinHash, Jaccard estimate, banded LSH index | Set-similarity signature and candidate search |
| [`simhash.cs`](../../../../ThermoMapper/src/hashish/simhash.cs) | BM25/IDF-weighted 64-bit SimHash and Hamming distance | Angular near-duplicate signature |
| [`ctph.cs`](../../../../ThermoMapper/src/hashish/ctph.cs) | Dual-resolution content-triggered piecewise digest and sequence comparison | Fuzzy file-family concept |
| [`tlsh.cs`](../../../../ThermoMapper/src/hashish/tlsh.cs) | Window buckets, quartiles, compact digest, simplified distance | Locality-sensitive whole-content concept |
| [`levenshtein.cs`](../../../../ThermoMapper/src/hashish/levenshtein.cs) | Character edit distance and normalized similarity | Exact sequence comparison |
| [`jaccard.cs`](../../../../ThermoMapper/src/hashish/jaccard.cs) | Jaccard, containment, overlap coefficient, Dice, word-shingle helpers | Exact set comparison |
| [`cos.cs`](../../../../ThermoMapper/src/hashish/cos.cs) | Cosine, angular distance, normalization, distance matrix | Exact vector comparison |
| [`ncd.cs`](../../../../ThermoMapper/src/hashish/ncd.cs) | Brotli/Deflate/GZip/ZLib normalized compression comparison | Heuristic representation-free comparison |
| [`measure.cs`](../../../../ThermoMapper/src/hashish/measure.cs) | Common distance/similarity interface and adapters | Pairwise orchestration abstraction |
| [`tokenizer.cs`](../../../../ThermoMapper/src/hashish/tokenizer.cs) | Unicode normalization, case folding, `\w+` tokenization | Text representation |
| [`shingler.cs`](../../../../ThermoMapper/src/hashish/shingler.cs) | Ordered and set-valued word n-grams | Local-order text features |
| [`histogram.cs`](../../../../ThermoMapper/src/hashish/histogram.cs) | Smoothed count normalization and unigram PMFs | Probability-distribution features |
| [`idf.cs`](../../../../ThermoMapper/src/hashish/idf.cs) | Document frequency, average length, three IDF formulas | Corpus-specific feature weighting |
| [`bm25.cs`](../../../../ThermoMapper/src/hashish/bm25.cs) | Average length and smoothed IDF tuple for SimHash | Legacy fitted-weight adapter |
| [`tfidf.cs`](../../../../ThermoMapper/src/hashish/tfidf.cs) | Tokenized corpus, fitted model, dense/sparse transforms | Lexical vectorization |
| [`tfidf_search.cs`](../../../../ThermoMapper/src/hashish/tfidf_search.cs) | Query scoring, nearest documents, bounded top-K | Local lexical retrieval |
| [`cooc.cs`](../../../../ThermoMapper/src/hashish/cooc.cs) | Windowed token co-occurrence model | Distributional corpus representation |
| [`cooc_stats.cs`](../../../../ThermoMapper/src/hashish/cooc_stats.cs) | PMI/PPMI, conditional probability, context vectors, entropy, neighbors | Association and distributional semantics |

All 22 canonical source files are represented above.

## Practical conceptual priority

If the goal is to extract value rather than port the directory wholesale, a sensible order is:

1. keep cryptographic identity as a separate foundational capability;
2. establish explicit text/view profiles through tokenizer and shingling concepts;
3. retain exact measures as oracles and directly useful tools inside the backend;
4. use TF-IDF/search where a real lexical retrieval workload exists;
5. add MinHash/LSH or SimHash only when candidate-search scale justifies lossiness;
6. use Bloom, Count-Min, or HLL only for a measured streaming-state problem;
7. explore co-occurrence/PPMI for corpus archaeology or semantic-neighbor work with a bounded vocabulary;
8. defer CTPH/TLSH until a concrete file-family workload justifies conformance work;
9. treat NCD as an exploratory comparator rather than a default index.

This preserves Hashish's real conceptual contribution: not a pile of tools, but a vocabulary for deciding what kind of sameness, resemblance, relevance, association, or approximation a given problem actually requires.
