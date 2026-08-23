# jobs — handle plane. Receipts until an explicit `read` of one id.
# Mailbox protocol is hidden. One reserved int tag; identity rides in the record.
# Mutating verbs are `export def --env` so `$env.JOBS` / `$env.NU_PAR` survive evaluates.

# Module-reserved mailbox tag. User-land `job send --tag` must not use this value.
const JOBS_MBOX = 0x4A4F4253

export-env {
    if ($env.JOBS? == null) {
        $env.JOBS = []
    }
}

# Overlay `use *` does not leak into this module's scope. Import cores and par here.
use core/census.nu [shape]
use core/meta.nu ["meta stamp"]
use par ["par cap" "par budget" "par emit"]

# --- pure helpers -------------------------------------------------------------

def jobs-short [msg: string]: nothing -> string {
    let line = ($msg | lines | first | default "")
    if ($line | str length) <= 240 { $line } else { $line | str substring 0..239 }
}

def jobs-census [payload]: nothing -> record {
    let s = ($payload | shape)
    {bytes: $s.bytes, type: $s.type, length: $s.length}
}

def jobs-stamp-receipt [
    rec
    verb: string
    --tag: any
    --elapsed: any
] {
    try {
        if $tag != null and $elapsed != null {
            $rec | meta stamp --verb $verb --tag $tag --elapsed $elapsed
        } else if $tag != null {
            $rec | meta stamp --verb $verb --tag $tag
        } else if $elapsed != null {
            $rec | meta stamp --verb $verb --elapsed $elapsed
        } else {
            $rec | meta stamp --verb $verb
        }
    } catch {
        $rec
    }
}

def jobs-project [row: record]: nothing -> record {
    {
        seq: $row.seq
        tag: $row.tag
        job_id: $row.job_id
        ok: $row.ok
        status: $row.status
        bytes: $row.bytes
        type: $row.type
        length: $row.length
        error: $row.error
        started: $row.started
        finished: $row.finished
        elapsed: $row.elapsed
    }
}

def jobs-running []: nothing -> int {
    if ($env.JOBS? == null) or ($env.JOBS | is-empty) { 0 } else {
        $env.JOBS | where status == "running" | length
    }
}

def jobs-live-ids []: nothing -> list<int> {
    let live = (try { job list } catch { [] })
    if ($live | is-empty) { [] } else { $live | get id }
}

def jobs-find [key]: nothing -> any {
    if ($env.JOBS? == null) or ($env.JOBS | is-empty) { return [] }
    let d = ($key | describe)
    if $d =~ '^int' {
        $env.JOBS | where job_id == $key
    } else {
        $env.JOBS | where tag == ($key | into string)
    }
}

def jobs-next-seq []: nothing -> int {
    if ($env.JOBS? == null) or ($env.JOBS | is-empty) { 0 } else {
        ($env.JOBS | get seq | math max) + 1
    }
}

def jobs-require-par [] {
    if ($env.NU_PAR? == null) {
        error make {msg: "jobs: $env.NU_PAR missing; load par first (`use par *`)"}
    }
}

# --- env-mutating harvest -----------------------------------------------------

def --env jobs-apply [msg: record] {
    if ($env.JOBS? == null) or ($env.JOBS | is-empty) { return }
    $env.JOBS = (
        $env.JOBS | each {|row|
            if $row.tag == $msg.tag and $row.status == "running" {
                let finished = (date now)
                let payload = $msg.output
                let census = (jobs-census $payload)
                $row | merge {
                    ok: $msg.ok
                    status: (if $msg.ok { "completed" } else { "failed" })
                    error: (if $msg.ok { null } else { (jobs-short ($msg.error | default "error")) })
                    output: $payload
                    bytes: $census.bytes
                    type: $census.type
                    length: $census.length
                    finished: $finished
                    elapsed: ($finished - $row.started)
                }
            } else { $row }
        }
    )
}

def --env jobs-drain [] {
    loop {
        let msg = (try { job recv --tag $JOBS_MBOX --timeout 0sec } catch { null })
        if $msg == null { break }
        jobs-apply $msg
    }
}

# `ids` is a snapshot of native `job list` taken BEFORE the last drain (see jobs-harvest).
def --env jobs-reconcile [ids: list<int>] {
    if ($env.JOBS? == null) or ($env.JOBS | is-empty) { return }
    let now = (date now)
    $env.JOBS = (
        $env.JOBS | each {|row|
            if $row.status == "running" and not ($row.job_id in $ids) {
                $row | merge {
                    ok: false
                    status: "failed"
                    error: "vanished"
                    finished: $now
                    elapsed: ($now - $row.started)
                }
            } else { $row }
        }
    )
}

# Liveness order: snapshot `job list` BEFORE the final drain, then drain, then reconcile
# against the snapshot. A job absent from the snapshot has either already sent (its
# message precedes its exit, so the drain applies it and it is no longer `running`) or
# is truly gone. Snapshotting AFTER the drain leaves a window where a job that sent and
# exited between the two is falsely marked vanished and its message is later dropped.
def --env jobs-harvest [timeout: duration = 0sec] {
    jobs-drain
    if $timeout > 0sec {
        let deadline = ((date now) + $timeout)
        loop {
            if (jobs-running) == 0 { break }
            let remaining = ($deadline - (date now))
            if $remaining <= 0sec { break }
            let msg = (try { job recv --tag $JOBS_MBOX --timeout $remaining } catch { null })
            if $msg == null { break }
            jobs-apply $msg
            jobs-drain
        }
    }
    let ids = (jobs-live-ids)
    jobs-drain
    jobs-reconcile $ids
}

def --env jobs-require-row [key] {
    jobs-harvest 0sec
    let hit = (jobs-find $key)
    if ($hit | is-empty) {
        error make {msg: $"jobs: no job matching ($key)"}
    }
    $hit | first
}

# --- exports ------------------------------------------------------------------

# Spawn a background job. Returns a running receipt, or `{ok: false, error: "budget", budget}` at cap.
# Duplicate `tag` is refused. Payload is quarantined in `$env.JOBS` until `jobs read` / `jobs fetch`.
export def --env "jobs spawn" [
    work: closure                           # Work to run in a background job (`{ ... }`)
    --tag: string                           # Unique session tag (lookup key; also native --description)
] {
    jobs-require-par
    jobs-harvest 0sec
    if ($env.JOBS? != null) and (not ($env.JOBS | is-empty)) {
        if not ($env.JOBS | where tag == $tag | is-empty) {
            return (jobs-stamp-receipt {ok: false, error: "duplicate tag", tag: $tag} "jobs.spawn" --tag $tag)
        }
    }
    let ceiling = $env.NU_PAR.ceiling
    let inflight = (jobs-running)
    if $inflight >= $ceiling {
        return (jobs-stamp-receipt {
            ok: false
            error: "budget"
            budget: {
                ceiling: $ceiling
                inflight: $inflight
                cores: $env.NU_PAR.cores
            }
        } "jobs.spawn")
    }
    let seq = (jobs-next-seq)
    let started = (date now)
    let mbox = $JOBS_MBOX
    let id = (job spawn --description $tag {
        let packed = (try {
            {tag: $tag, ok: true, output: (do $work), error: null}
        } catch {|e|
            {tag: $tag, ok: false, output: null, error: $e.msg}
        })
        $packed | job send 0 --tag $mbox
    })
    let row = {
        seq: $seq
        tag: $tag
        job_id: $id
        ok: true
        status: "running"
        bytes: null
        type: null
        length: null
        error: null
        started: $started
        finished: null
        elapsed: null
        output: null
    }
    $env.JOBS = ($env.JOBS | default [] | append $row)
    jobs-stamp-receipt (jobs-project $row) "jobs.spawn" --tag $row.tag
}

# All registry rows, seq ascending. Drains ready messages then reconciles vanished. No payloads.
export def --env "jobs list" []: nothing -> any {
    jobs-harvest 0sec
    if ($env.JOBS? == null) or ($env.JOBS | is-empty) { return [] }
    $env.JOBS | sort-by seq | select seq tag job_id ok status bytes type length error started finished elapsed
}

# Finished receipts only (`completed|failed|cancelled`), seq order. Partial = what's done.
# Never `job recv` without timeout. Default 5sec (short bound); pass 0sec to drain ready.
export def --env "jobs collect" [
    --timeout: duration = 5sec              # Max wait; 0sec drains ready and returns
]: nothing -> any {
    jobs-harvest $timeout
    if ($env.JOBS? == null) or ($env.JOBS | is-empty) { return [] }
    $env.JOBS
    | where {|r| $r.status in ["completed" "failed" "cancelled"]}
    | sort-by seq
    | select seq tag job_id ok status bytes type length error started finished elapsed
}

# Shape only: census, no body. `key` is job_id (int) or tag (string).
# Census fields from `$payload | shape` internally. Not `jobs read | shape`.
export def --env "jobs inspect" [
    key: any                                # job_id (int) or tag (string)
]: nothing -> record {
    let row = (jobs-require-row $key)
    mut rec = {
        seq: $row.seq
        tag: $row.tag
        job_id: $row.job_id
        ok: $row.ok
        status: $row.status
        type: $row.type
        length: $row.length
        bytes: $row.bytes
        error: $row.error
        started: $row.started
        finished: $row.finished
        elapsed: $row.elapsed
    }
    let payload = $row.output
    if $payload != null {
        let s = ($payload | shape)
        $rec = ($rec | upsert type $s.type | upsert length $s.length | upsert bytes $s.bytes)
        if ("columns" in ($s | columns)) {
            $rec = ($rec | upsert columns ($s.columns | get name))
        }
    }
    jobs-stamp-receipt $rec "jobs.inspect" --tag $row.tag --elapsed $row.elapsed
}

# Portable `read` of one stored payload. Peek, not pop — repeatable. One id only.
# Under cap → body. Over cap → decline naming `jobs fetch <tag>`. Still running → error. Does not re-stash.
export def --env "jobs read" [
    key: any                                # job_id (int) or tag (string)
]: nothing -> any {
    let row = (jobs-require-row $key)
    if $row.status == "running" {
        error make {msg: $"jobs: '($key)' still running"}
    }
    let payload = $row.output
    let census = (jobs-census $payload)
    let bytes = $census.bytes
    let cap = (par cap)
    if $bytes == null or $bytes <= $cap {
        return $payload
    }
    jobs-stamp-receipt {
        ok: true
        disclosed: false
        tag: $row.tag
        bytes: $bytes
        retrieve: $"jobs fetch ($row.tag)"
    } "jobs.read" --tag $row.tag
}

# Uncapped retrieve of one stored payload. Peek, not pop. Still running → error.
# The retrieve named by a declining `read`. Compose: `jobs fetch t | page`.
export def --env "jobs fetch" [
    key: any                                # job_id (int) or tag (string)
]: nothing -> any {
    let row = (jobs-require-row $key)
    if $row.status == "running" {
        error make {msg: $"jobs: '($key)' still running"}
    }
    $row.output
}

# Store a value in the registry as a completed-on-arrival row (no native job; `job_id: null`).
# Returns the receipt. The value is then `inspect`/`read`-able like any job payload.
# This is the quarantine primitive for query wrappers; `jobs emit` is built on it.
export def --env "jobs stash" [
    --tag: string                           # Unique session tag; default `stash:<seq>`
]: any -> record {
    let payload = $in
    jobs-harvest 0sec
    let seq = (jobs-next-seq)
    let tag = (if $tag != null { $tag } else { $"stash:($seq)" })
    if ($env.JOBS? != null) and (not ($env.JOBS | is-empty)) {
        if not ($env.JOBS | where tag == $tag | is-empty) {
            return (jobs-stamp-receipt {ok: false, error: "duplicate tag", tag: $tag} "jobs.stash" --tag $tag)
        }
    }
    let now = (date now)
    let census = (jobs-census $payload)
    let row = {
        seq: $seq
        tag: $tag
        job_id: null
        ok: true
        status: "completed"
        bytes: $census.bytes
        type: $census.type
        length: $census.length
        error: null
        started: $now
        finished: $now
        elapsed: 0sec
        output: $payload
    }
    $env.JOBS = ($env.JOBS | default [] | append $row)
    jobs-stamp-receipt (jobs-project $row) "jobs.stash" --tag $tag --elapsed 0sec
}

# Query envelope with quarantine: `par emit`, plus — when truncated — the full findings
# table is stashed under `tag` so `jobs fetch <tag>` retrieves it. Envelope gains `tag`
# only when something was stored. Foreground `par emit` alone is lossy over cap.
export def --env "jobs emit" [
    --tag: string                           # Registry tag for the stored findings; default `emit:<seq>`
]: any -> record {
    jobs-require-par
    let findings = $in
    let envelope = ($findings | par emit)
    if not $envelope.truncated { return $envelope }
    let tag = (if $tag != null { $tag } else { $"emit:(jobs-next-seq)" })
    let receipt = ($findings | jobs stash --tag $tag)
    if ($receipt.ok? == false) and ($receipt.error? == "duplicate tag") {
        return ($envelope | insert error "duplicate tag" | insert tag $tag)
    }
    $envelope | insert tag $tag
}

# Kill a running job and stamp the row. A killed job never sends; collect must not wait on it.
export def --env "jobs cancel" [
    id: int                                 # Native job_id
]: nothing -> record {
    jobs-harvest 0sec
    let hit = (jobs-find $id)
    if ($hit | is-empty) {
        return (jobs-stamp-receipt {job_id: $id, cancelled: false} "jobs.cancel")
    }
    let row = ($hit | first)
    if $row.status != "running" {
        return (jobs-stamp-receipt {job_id: $id, cancelled: false} "jobs.cancel" --tag $row.tag)
    }
    try { job kill $id } catch { }
    let finished = (date now)
    let elapsed = ($finished - $row.started)
    $env.JOBS = (
        $env.JOBS | each {|r|
            if $r.job_id == $id and $r.status == "running" {
                $r | merge {
                    ok: false
                    status: "cancelled"
                    error: "cancelled"
                    finished: $finished
                    elapsed: $elapsed
                }
            } else { $r }
        }
    )
    jobs-stamp-receipt {job_id: $id, cancelled: true} "jobs.cancel" --tag $row.tag --elapsed $elapsed
}

# Knobs, cores, ceiling, inflight, policy. No job rows. Harvests ready so inflight is true.
export def --env "jobs status" []: nothing -> record {
    jobs-require-par
    jobs-harvest 0sec
    jobs-stamp-receipt ($env.NU_PAR | merge {inflight: (jobs-running)}) "jobs.status"
}

# Session-scoped knob mutation. Recalculates ceiling via `par budget`; does not write policy.json.
export def --env "jobs policy" [
    --max-workers: int                      # Explicit ceiling request (clamped to cores)
    --reserved-cores: int                   # Cores kept for the REPL (auto policy)
    --min-items-per-worker: int             # Grade K for `par` maps
    --max-inline-bytes: any                 # Query envelope cap; null in JSON → NU_MCP_OUTPUT_LIMIT
]: nothing -> record {
    jobs-require-par
    mut p = $env.NU_PAR
    if $max_workers != null {
        $p = ($p | upsert max_workers $max_workers)
    }
    if $reserved_cores != null {
        $p = ($p | upsert reserved_cores $reserved_cores)
    }
    if $min_items_per_worker != null {
        $p = ($p | upsert min_items_per_worker $min_items_per_worker)
    }
    if $max_inline_bytes != null {
        $p = ($p | upsert max_inline_bytes $max_inline_bytes)
    }
    let b = (
        if $p.max_workers == null {
            par budget 1 --cores $p.cores --reserved-cores $p.reserved_cores --min-items-per-worker $p.min_items_per_worker
        } else {
            par budget 1 --cores $p.cores --reserved-cores $p.reserved_cores --min-items-per-worker $p.min_items_per_worker --threads $p.max_workers
        }
    )
    if $b.warning != null { print -e $b.warning }
    $env.NU_PAR = (
        $p
        | upsert ceiling $b.ceiling
        | upsert policy (if $p.max_workers == null { "auto" } else { "explicit" })
    )
    $env.NU_PAR
}
