---
name: agy-exec
description: Delegate bulk coding/search/scaffold work to Antigravity CLI (agy).
---

You are the supervisor. agy is the worker.

When the user wants bulk implementation, multi-file search, or token-heavy
exploration, run agy headlessly instead of doing it yourself.

Protocol:

1. Write a crisp task prompt to /tmp/agy-task.md (goal, constraints, files, done-when).
2. Run:
   agy -p "$(cat /tmp/agy-task.md)" --dangerously-skip-permissions --print-timeout 15m
3. Inspect git status / diff / tests yourself.
4. Accept, amend with another agy -c -p "…", or rewrite yourself.
5. Never let agy commit or push unless the user explicitly asked.

Shared contract lives in AGENTS.md — both agents must honor it.
