Viewed formatting.ts:1-331
Viewed render-test.mjs:1-100
Searched for "parseAnchor"
Viewed engine.ts:800-835
Viewed journal-test.mjs:1-120

When we examine how the **context stream** (what `mdnav_read`, `batch_read`, `outline`, and `locate` emit) and the **journal** (`mdnav_journal_record`, `journal_read`, `journal_tree`, and `coverage`) interact, having them agree completely—in token identity, punctuation grammar, and documentation—is essential.

Here is a breakdown of how they align, where friction currently exists, and how to bring them into total agreement:

---

### 1. Where They Already Agree (The Architectural Shared Grammar)

Both the context stream and journal share a unified rank-ordered punctuation grammar:

| Rank | Mark | Role | Context Stream Example | Journal Example |
|---|---|---|---|---|
| **Field** | ` \| ` | Separates columns/fields | `D023 : H0006 @ e5f6 \| 8420 .. 9860 \|` | `N003 \| 20260828_194530Z \| adopt \| ...` |
| **Item** | ` ; ` | Separates items in a list | *(Multi-unit packets)* | `D023 : H0006 @ e5f6 ; code : grassmann.py` |
| **Scope** | ` : ` | Scope containment | `D023 : H0006` | `D023 : H0006` |
| **Version**| ` @ ` | Content identity / digest | `H0006 @ e5f6` | `H0006 @ e5f6` |
| **Range** | ` .. ` | Byte-span boundaries | `8420 .. 9860` | *(Span anchors / offsets)* |
| **Empty** | `-` | Missing/unassigned field | `doc \| - \| span` (no heading) | `refs: - \| concept: -` |

Because both systems use space-isolated operators (` : `, ` @ `, ` ; `, ` | `), a token like `D023` or `H0006` presents the **exact same token sequence** in an outline row, in a stream frame header, in the closing bracket, and in a journal line.

---

### 2. Friction Points & Disagreements

#### A. The "Quote Verbatim" vs. "Pass Compact" Contradiction
In [SKILL.md](file:///d:/aghado01/science-facility/mcp/mdnav/skills/doc-dive/SKILL.md), two adjacent instructions pull in opposite directions:
- Line 178: *"Quote anchors exactly as given. A restyled citation loses the binding."*
- Line 180: *"Pass anchors back compact (`D014:H0003@a1b2`); the stream spaces them out."*

**The Problem:**
If the stream emits `D023 : H0006 @ e5f6` and the model is told to quote anchors exactly as given, it will naturally pass `anchors: ["D023 : H0006 @ e5f6"]`. 
However, if the parser expects compact strings or doesn't trim components, the space-padded strings can fail internal regexes or equality checks (e.g., `"D023 "` vs `"D023"`).

#### B. Documentation Example Discrepancies (Receipts & Examples)
In several places, the documentation accidentally used fused anchors in receipts even though `formatting.ts` emits spaced anchors:
- In [SKILL.md](file:///d:/aghado01/science-facility/mcp/mdnav/skills/doc-dive/SKILL.md#L97):
  ```
  → recorded | N001 (+28 B) | propose | - | C-001 | D001:H0003@a1b2
  ```
  *(Fused in doc example, but `formatting.ts:327` renders `D001 : H0003 @ a1b2`)*
- In [state-and-audit.md](file:///d:/aghado01/science-facility/mcp/mdnav/skills/doc-dive/references/state-and-audit.md#L143):
  ```
  recorded | N003 (+148 B) | adopt | N002 | C-001 | D023:H0006@e5f6 ; code:grassmann.py
  ```
  *(Fused receipt example, directly below an un-fused ledger example)*
- In [chat-archaeology.md](file:///d:/aghado01/science-facility/mcp/mdnav/skills/doc-dive/references/chat-archaeology.md#L29):
  ```markdown
  - [P-014] D001:H0018: Propose 5-point admission test ...
  ```
  *(Manual markdown list item rather than a journal entry)*

#### C. Parser Whitespace Resilience (`parseAnchor`)
In `src/formatting.ts`, `parseAnchor` splits on `:` and `@`. If the incoming string is space-isolated (`"D001 : H0003 @ a1b2"`), `scope` and `unit` can retain leading/trailing whitespace (`"D001 "` and `" H0003 "`) unless `.trim()` is applied to every component. Trimming makes the system 100% invariant whether passed compact or spaced.

---

### 3. How to Make Them Fully Agree

1. **Permissive Input, Deterministic Output:**
   - `parseAnchor()` trims `scope`, `unit`, and `digest` so `D001 : H0003 @ a1b2` and `D001:H0003@a1b2` are treated identically as tool inputs.
   - All tool emitters (stream headers, stream closes, journal ledger lines, journal receipts) consistently format anchors as `D001 : H0003 @ a1b2`.

2. **Unify the Writing Across the Skill and References:**
   - Standardize all receipt examples in [SKILL.md](file:///d:/aghado01/science-facility/mcp/mdnav/skills/doc-dive/SKILL.md) and [state-and-audit.md](file:///d:/aghado01/science-facility/mcp/mdnav/skills/doc-dive/references/state-and-audit.md) to show the true spaced output: `D001 : H0003 @ a1b2`.
   - Update [SKILL.md](file:///d:/aghado01/science-facility/mcp/mdnav/skills/doc-dive/SKILL.md) guidance: clarify that whether an agent passes anchors spaced (copied verbatim from the stream) or compact, they resolve identically and emit space-isolated.
   - Update [chat-archaeology.md](file:///d:/aghado01/science-facility/mcp/mdnav/skills/doc-dive/references/chat-archaeology.md) to use `mdnav_journal_record` for proposal tracking instead of ad-hoc markdown lists.