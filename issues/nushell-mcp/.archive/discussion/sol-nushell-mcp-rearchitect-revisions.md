Yes—`core/` containing focused `.nu` unit modules is cleaner. It also avoids the nested `core/census/mod.nu` discovery problem and removes the need for an umbrella name like `dataspection-primitives`.

I would split the current implementation like this:

```text
modules/
  core/
    failure.nu       # normalize caught Nu errors
    value.nu         # common value facts and NUON measurement
    census.nu        # shape, shape each
    schema.nu        # schema, diff, check, stats
    spine.nu         # spine
    views.nu         # preview, page
    meta.nu          # meta, meta stamp
    capture.nu       # later: process capture for xq/rg

  dataspection/
    mod.nu           # façade exports core commands and defines read
```

## Core units

### `failure.nu`

The layer-wide caught-error convention:

```nu
failure fields <error>
→ {error: string, trace: string}
```

This replaces duplicated `catch-fields` implementations. It does not throw; it normalizes a caught Nu error for inclusion in failure-as-data results.

### `value.nu`

Low-level facts shared across several operations:

```nu
value kind
value columns
value nuon
```

Responsibilities:

- Normalized closed type names.
- Safe column discovery.
- NUON serialization and UTF-8 byte measurement.
- Serialization failure represented as data.

`value nuon` can return:

```nu
{ok: true, bytes, nuon}
```

or:

```nu
{ok: false, bytes: null, nuon: "", error, trace}
```

This is the internal source for the single `bytes` definition. `shape` remains the authoritative agent-facing census contract.

### `census.nu`

Exports:

```nu
shape
shape each
```

Private helpers remain colocated:

- `head-of`
- `shape-core`
- `shape-each-row`
- `fail-shape`

Imports only the necessary `value` and `failure` commands.

This is what `par` and `jobs` consume.

### `schema.nu`

Exports the complete schema family:

```nu
schema
schema diff
schema check
schema stats
```

Keeps these private helpers together:

- `percentile-95`
- `split-path`
- `values-at`
- `walk-paths`
- `population-members`

Schema is cohesive enough to remain one unit; splitting its subcommands would expose internal traversal machinery without improving dependency boundaries.

### `spine.nu`

Exports only:

```nu
spine
```

It deserves its own unit because rg needs it without needing schema traversal or bounded-view code.

### `views.nu`

Exports:

```nu
preview
page
```

These are the bounded disclosure views. `views.nu` owns the clipping helpers:

- `already-clipped-str`
- `already-clipped-list`
- `clip-str`
- `clip-list`
- `preview-impl`

`page` shares the same conceptual responsibility even though it does not share much implementation: one safe, bounded view of a value already in hand.

If you want maximum granularity, `preview.nu` and `page.nu` could be separate, but `views.nu` is still a tight and useful unit.

### `meta.nu`

Exports:

```nu
meta
meta stamp
```

Keeps the private stamp construction together. `jobs` imports only `"meta stamp"`.

This preserves the existing semantic claim: metadata is data. The file boundary does not turn metadata into a separate agent-facing practice.

### `capture.nu` later

Exports the unbounded process-capture mechanism needed before terminal return policy:

```nu
process capture <cmd> [...args]
→ {stdout, stderr, exit_code, elapsed}
```

Both xq and rg consume it. Ordinary xq remains the safe agent-facing command that applies census, cap, and quarantine.

`process capture` is preferable to a generic flat `capture` command because the noun domain makes its scope explicit.

## Dataspection façade

The façade becomes mostly composition:

```nu
export use core/census.nu *
export use core/schema.nu *
export use core/spine.nu *
export use core/views.nu *
export use core/meta.nu *

use core/failure.nu ["failure fields"]
use core/census.nu [shape]
use core/meta.nu ["meta stamp"]
use par ["par cap"]
use jobs ["jobs stash"]

export def --env read [] {
    # guarded full disclosure
}
```

Agents still receive exactly:

```nu
use dataspection *

$x | shape
$x | schema
$x | spine file
$x | preview
$x | page
$x | meta
$x | read
```

The support commands from `core/value.nu` and `core/failure.nu` are not re-exported.

## Dependency map

```text
failure
   ▲
 value
   ▲
   ├──── census ◄──── par
   │        ▲
   │        └──────── jobs
   ├──── schema
   ├──── spine ◄───── rg
   ├──── views
   └──── meta ◄────── jobs

dataspection façade
   ├── exports census/schema/spine/views/meta
   ├── uses par cap
   ├── uses jobs stash
   └── owns read
```

This gives each file a real semantic identity, keeps shared helper contracts narrow, and avoids treating the whole pure half of dataspection as one vaguely named primitive module. The important constraint is that cross-file helpers must become explicitly exported, qualified core commands—such as `value kind` and `failure fields`—while the façade re-exports only the intended agent-facing commands.
