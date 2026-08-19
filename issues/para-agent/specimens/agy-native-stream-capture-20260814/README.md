# AGY native stream capture attempt — 2026-08-14

**This capture contains no stream.** It is retained because *why* it contains no stream is the
evidence.

> **Which "agy" this is.** The *application*: Google Antigravity CLI `agy.exe`, the binary at
> `%LOCALAPPDATA%\agy\bin\agy.exe`, targeted by adapter `agy/unverified-v1`.
>
> It is **not** the adjutant *role* named `agy` from the prototype era. That was a standing psmux
> pane in session `agent-agy`, driven by headless `claude.exe -p` — four productive engagements
> 2026-08-10→13, recorded in
> [agy-usage-report-20260813_100903.md](../agy-usage-report-20260813_100903.md) and
> [fable-agy-TexDig-triage-20260812.md](../fable-agy-TexDig-triage-20260812.md). Those sessions
> evidence the role's mechanics and Claude's stream. They say nothing about this application, and
> the two are routinely conflated because they share a short name.

| | |
|---|---|
| Application | `agy` (Antigravity) `1.1.13` |
| Launched | 2026-08-14T21:21:19Z → 21:22:20Z (61s) |
| cwd | `D:\aghado01\science-facility` |
| Exit | code `1`, no signal |
| stdout | **0 bytes** |
| stderr | 939 bytes |

## What happened

`agy.exe --print --output-format stream-json --mode plan --sandbox --disable-slash-commands
--print-timeout 2m` was spawned non-interactively. It responded with a Google OAuth device-login
prompt:

```
Authentication required. Please visit the URL to log in:
  https://accounts.google.com/o/oauth2/auth?...
Waiting for authentication (timeout 60s)...
Or, paste the authorization code here and press Enter:
Error: authentication timed out.
Error: authentication failed or timed out
```

It exited after its own 60-second auth timeout, having emitted **zero native events**.

## What it proves, and what it does not

**Proves:** para-agent's non-interactive spawn path cannot complete AGY's interactive browser OAuth
flow. There is no headless credential channel in the probed invocation — no API-key equivalent was
supplied or attempted. This is an **authentication-carrier** gap.

**Does not prove** anything about AGY's stream format, event schema, terminal predicates, reply
reconstruction, or adapter correctness. None of that was reached. Any statement that AGY "failed a
stream capture" is unsupported by this artifact — the capture never began.

## Why this file exists

The capture originally sat in `.codex/agy-native-stream-capture/` — a gitignored directory named
for an unrelated vendor. It was therefore invisible to the repository and uncited by any planning
document, including P12, which was written afterward and describes AGY as awaiting exactly this
evidence. Moved here 2026-08-19; see
[misplaced-artifacts-audit-20260819](../../reports/misplaced-artifacts-audit-20260819.md) F2.

## Files

| File | |
|---|---|
| `metadata.json` | launch record — argv, cwd, timings, prompt hash, exit, stream byte counts and hashes |
| `stderr.raw` | the auth prompt and timeout, verbatim |
| `stdout.raw` | empty, retained deliberately as the 0-byte fact |
| `agy-native-stream-probe.mjs` | the probe that produced this capture |

## To retry

Needs a headless credential path for AGY before a spawn probe can reach the stream — or an
interactive-auth carrier, which para-agent does not have and which would be a separate design
question. Establish that first; re-running the probe unchanged will reproduce this file.
