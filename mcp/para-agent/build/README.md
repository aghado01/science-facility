# build/

Regenerable working output. Everything here is disposable by design: deleting the whole directory
must cost nothing but the time to regenerate it.

Plays the role `artifacts/` plays in `codex-scientiae`. Renamed because para-agent has no compile
step of its own — what lands here is fetch caches, staging, and run output rather than object files.

**Everything here is ignored** (`build/**`, with this file ignore-negated). This file is the only
tracked content under `build/`.

## The rule

**Every write is scoped under a module or process-name subfolder.** Nothing writes a bare
`build/cache`, `build/staging`, or `build/tmp`. This directory is shared by every process that
emits regenerable output, so an unscoped top-level folder collides with all of them and makes it
impossible to clear one module's output without disturbing the rest.

The first segment names a **module** or a **process**, never an output kind:

- **Every stage of one module's own work belongs to that module** — fetch cache, staging, and
  verification output sit together under `build/{module}/`, so one module's entire working
  footprint is one deletable directory. Output kinds are the *second* segment, never the first.
- **A process bucket is for cross-cutting output** that is not a stage of any one module's work,
  such as test runs.

```text
build/node/npm-cache/        npm's download cache, module-scoped
build/{module}/staging/      payload staging, pre-release into deps/{module}/
build/test-runs/{stamp}/     cross-cutting run output
```

The operating-system temp tree is not a project scratch fallback. Work that needs a scratch
directory declares one below this root.

## Nothing is delivered from here

`build/` is working output only, and every path in it is disposable. A payload other parts of
para-agent consume is **released** to `deps/{module}/` — same module scoping, but a destination
with a real lifetime. The recipe in `brewery/{module}/` owns the hand-off: stage here, verify the
expected payload is present, then move it into `deps/{module}/`. Never point a consumer at a path
under `build/`.

## How it is enforced

By the recipes that write here, and nothing else. para-agent has no `Directory.Build.props`
equivalent deriving output paths automatically, because it has no .NET projects — so scoping is a
convention each recipe follows explicitly, the way `restore-*.ps1` does rather than the way MSBuild
does.

## Current state

Empty. Nothing routes here yet. The first occupant should be `build/node/npm-cache/` when the node
restore recipe is written; see [brewery/README.md](../brewery/README.md).
