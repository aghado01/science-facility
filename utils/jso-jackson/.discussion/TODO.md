# JSO Tools TODO

Outstanding items to consider later. This is intentionally a parking lot, not a commitment to implement everything.

## Architecture Backlog

- Evaluate whether `jso-jackson.ps1` should remain a PowerShell engine long-term.
  - Trigger to revisit: large corpus sizes, slow repeated scans, painful test setup, or frequent regressions in JSON serialization/index behavior.
  - Possible direction: compiled CLI in Go, Rust, or C# while keeping the PowerShell functions as wrappers.

- Replace `ClaudeRecordAnnotator::Annotate` with a no-roundtrip JSON writer.
  - Current path goes `JsonElement -> ConvertFrom-Json -> PSCustomObject -> ConvertTo-Json`.
  - Concern: PowerShell JSON conversion can mutate number types, property ordering, or edge-case values.
  - Requirement before changing: regression tests over representative Claude records, including nested content blocks, nulls, numbers, tool calls, and lateral/subagent records.

- Revisit `Get-ClaudeExchanges` streaming strategy.
  - Current design does a prescan for `tool_use_id -> tool_result` matching, then a second pass to emit exchanges.
  - Correctness currently matters more than avoiding the second pass.
  - Possible future direction: build a lightweight tool-result sidecar or index if large threads make the prescan expensive.

## RPC Design

- Decide whether RPC output should use flat per-job directories or a runstamp grouping layer.
  - Current documented default: `$env:CLAUDE_CONFIG_DIR\tmp\rpc\YYYYMMDD_HHmmss-<task>\`.
  - Possible grouped layout: `$env:CLAUDE_CONFIG_DIR\tmp\rpc\<runstamp>\001-<task>-<suffix>\` plus `run.json`.
  - Tradeoff: grouping improves cleanup and multi-step auditability, but flat dirs are simpler.

- Implement an `Invoke-JsoRpc` wrapper if the convention proves useful.
  - Inputs: command name, hashtable arguments, output format, optional out dir/runstamp.
  - Outputs: `request.json`, `summary.json`, primary result file, optional `errors.jsonl`, `stdout.txt`, `stderr.txt`.
  - Should return only a small manifest object to console.

- Define retention behavior for RPC artifacts.
  - README now says models should clean up scratch RPC dirs after work unless referenced or still useful.
  - Future wrapper could support `-Keep`, `-Cleanup`, or `-PruneDays`.

## LLM Ergonomics Follow-Ups

- Reassess whether `Find-JsonlRecord -Where` should be de-emphasized further.
  - It remains useful for humans and complex predicates.
  - Models should prefer `Find-JsonlByPath` or `Find-JsonlByCondition`.
  - Possible future option: richer declarative operators (`GreaterThan`, `LessThan`, `Contains`, `In`, `NotIn`).

- Add output caps to more search commands if model use shows repeated oversized console output.
  - Candidates: `Find-JsonlRecord`, `Find-JsonlByPath`, `Find-JsonlByCondition`, `Compare-JsonlFiles`, `Compare-JsonlByHash`.
  - Possible parameters: `-First`, `-Skip`, `-MaxResults`.

- Consider progress or warning signals for whole-file scans.
  - Avoid noisy progress by default.
  - Maybe emit `Write-Verbose` milestones or add `-Progress` for very large files.

- Consider a standard `-AsPath` / `-OutDir` convention for commands that are commonly large.
  - This may become unnecessary if `Invoke-JsoRpc` exists.

## Testing And Verification

- Add smoke tests for the recently added debug helpers.
  - `Find-JsonlByCondition`
  - `Get-JsonlValueDistribution -Top/-All`
  - `Measure-Jsonl -MaxRecords/-SampleRate`
  - `Get-JsonlSizeProfile -MaxRecords/-SampleRate`
  - `Get-JsonlPathStats -MaxValues/-SampleRate`
  - `Show-JsonlStructure` explicit row behavior

- Add regression test for merged output blank-line bug.
  - Scenario: duplicate `message.id` causes earlier record to be tombstoned.
  - Assertion: merged JSONL has no blank lines and `.jidx` line count matches nonblank record count.

- Add validation tests around hash and Bloom sidecars.
  - `New-JsonlHashIndex` / `Test-JsonlHashIndex`
  - `Save-BloomFilter` / `Read-BloomFilter`
  - `Find-JsonlDuplicates -JsonPath` and `-ContentHash`

## Documentation

- Keep README examples aligned with implemented behavior.
  - Especially RPC conventions, cleanup expectations, and model-safe search/profile examples.

- Consider moving design discussion notes out of active tool docs once decisions settle.
  - Candidates: `perplexity-jso-debug-feedback.md`, `rpc-followup.md`, old scratch notes.

- Add a short function inventory table for `jso-debug.ps1` once the surface stabilizes.
