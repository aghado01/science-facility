The problem is the closing ` ``` `'@` — PowerShell sees the backtick before `'@` and treats it as a line continuation, so the terminator is never found. I need to put the closing fence on its own line and use a separate `'@` on the next line. The cleanest fix: use double-quoted here-strings for the expected values (escaping backticks) so there's no ambiguity with the `'@` terminator.

Actually the simpler fix: split the trailing ` ``` ` onto its own line before `'@`.

Replacing 6 lines with 8 lines in [](file:///c%3A/Users/azrie/PDenv/UserGithub/PowerShellCore/ps.core.reposnapshot/rs.core/.tests/tree-toc-template.Tests.ps1)


```

```


Ran terminal command: pwsh -NoProfile -File "c:\Users\azrie\PDenv\UserGithub\PowerShellCore\ps.core.reposnapshot\rs.core\.tests\tree-toc-template.Tests.ps1"

All 41 pass. The `.Add()` noise is a cosmetic issue — the `$script:Results` list is being stomped into a fixed-size array by `Assert-True` which feeds through `Assert-Equal` which adds to the list, but the re-assignment of `$script:Results` inside the function via `+=` on an `[object[]]` creates a new fixed array each time. Easy fix: drop the `.Add()` — the list is only used for the failure summary and the `+=` path already works. But all tests actually pass so it's just noise. Let me silence it cleanly:

Replacing 17 lines with 17 lines in [](file:///c%3A/Users/azrie/PDenv/UserGithub/PowerShellCore/ps.core.reposnapshot/rs.core/.tests/tree-toc-template.Tests.ps1)

Searched for text `Results.Add` (`PowerShellCore` · `ps.core.reposnapshot/rs.core/.tests/tree-toc-template.Tests.ps1`), 1 result

Read [](file:///c%3A/Users/azrie/PDenv/UserGithub/PowerShellCore/ps.core.reposnapshot/rs.core/.tests/tree-toc-template.Tests.ps1#30-30), lines 30 to 50

Replacing 6 lines with 6 lines in [](file:///c%3A/Users/azrie/PDenv/UserGithub/PowerShellCore/ps.core.reposnapshot/rs.core/.tests/tree-toc-template.Tests.ps1)


```

```


Ran terminal command: pwsh -NoProfile -File "c:\Users\azrie\PDenv\UserGithub\PowerShellCore\ps.core.reposnapshot\rs.core\.tests\tree-toc-template.Tests.ps1"

Read [](file:///c%3A/Users/azrie/AppData/Roaming/Code/User/workspaceStorage/94a933608176e84d5a0bfa14ac0b436e/GitHub.copilot-chat/chat-session-resources/06a93f23-ddba-4833-82fe-a66f3eb0024d/toolu_vrtx_01EJRLXAuiAigxh8igyTprrt__vscode-1777213388088/content.txt#1-1), lines 1 to 20

Read [](file:///c%3A/Users/azrie/AppData/Roaming/Code/User/workspaceStorage/94a933608176e84d5a0bfa14ac0b436e/GitHub.copilot-chat/chat-session-resources/06a93f23-ddba-4833-82fe-a66f3eb0024d/toolu_vrtx_01EJRLXAuiAigxh8igyTprrt__vscode-1777213388088/content.txt#20-20), lines 20 to 60

The `.Add()` is still erroring — the `$script:Results` `List` is getting replaced by the fixed-size array that `Assert-True` creates when it calls `Assert-Equal` with a string cast, which triggers an internal pipeline that unrolls and reassigns `$script:Results`. The root cause: `$script:Results` is a module-scoped `List` but the functions inside the script don't have `[void]` protection against the pipeline rewriting it. The fix: stop using the List at all — just use `+=` directly which is already what works.

Replacing 3 lines with 3 lines in [](file:///c%3A/Users/azrie/PDenv/UserGithub/PowerShellCore/ps.core.reposnapshot/rs.core/.tests/tree-toc-template.Tests.ps1)


```

```


Replacing 6 lines with 6 lines in [](file:///c%3A/Users/azrie/PDenv/UserGithub/PowerShellCore/ps.core.reposnapshot/rs.core/.tests/tree-toc-template.Tests.ps1)


```

```


Ran terminal command: pwsh -NoProfile -File "c:\Users\azrie\PDenv\UserGithub\PowerShellCore\ps.core.reposnapshot\rs.core\.tests\tree-toc-template.Tests.ps1" 2>&1 | Select-String -Pattern 'PASS|FAIL|Results:'

41/41, clean.

Completed: *Run tests, verify output* (3/3)

Done. What was created:

**Expand-TocTemplate.ps1** — the engine + model builders:
- `Resolve-TemplateValue` — dotted path resolver, `this` support
- `Expand-Template` — 3-pass regex expander (`#each` → `#if` → scalars)
- `New-SnapshotTocModel` — model for JSON snapshot variant
- `New-ShardedTocModel` — model for sharded `.txt` variant
- `Expand-TocTemplate` — public entry point (renders + trims)
- `$script:TocTemplate` — single shared here-string template covering both variants via `{{#if SummaryLine}}`

**tree-toc-template.Tests.ps1** — 41 tests across all layers including full round-trip for both variants.

When ready to integrate, each `$sb.AppendLine(...)` block in RepoSnapshot.psm1 becomes two lines: dot-source the engine (once at module top), then call `Expand-TocTemplate | Set-Content`.

Made changes.
