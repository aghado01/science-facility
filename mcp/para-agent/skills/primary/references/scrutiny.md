# Progressive Disclosure & Scrutiny

There are two evidence stores. Do not merge them conceptually.

- The mediated transcript contains only accepted `delegate` exchanges projected from correlated native events.
- The Console Journal contains `run` turns and optional interactive capture. It cannot establish mediated exchange boundaries.

## Mediated transcript: `scrutinize`

List exchange summaries:

```json
{
  "handle": "review-seat"
}
```

Inspect receiver-native tool records for one exchange:

```json
{
  "handle": "review-seat",
  "xid": "xid-001",
  "filter": "tools"
}
```

Inspect one zero-based record step:

```json
{
  "handle": "review-seat",
  "xid": "xid-001",
  "step": 3
}
```

Call these objects with `scrutinize`. An unknown session returns an empty/not-found result without creating files. `thinking` means only reasoning material exposed by the native client. Check trace completeness and omissions before treating a slice as comprehensive.

## Read-only quarantine status

Inspect one exact mediation lane without opening a writer or creating a transcript:

```json
{
  "application": "claude",
  "handle": "review-seat"
}
```

Call this object with `quarantine_status`. Treat `blocked: true` as authoritative for refusing another mediated turn until an operator completes the separate offline recovery procedure. This public tool only reads the process gate and matching durable notices; it cannot clear quarantine.

## Console Journal: `log`, `body`, `find`

Orient with summaries:

```json
{
  "handle": "<returned-handle>",
  "view": "summary"
}
```

Search before fetching bodies:

```json
{
  "handle": "<returned-handle>",
  "pattern": "FAILED",
  "context": 2
}
```

Fetch a bounded body slice only when needed:

```json
{
  "handle": "<returned-handle>",
  "turn": 4,
  "grep": "FAIL",
  "context": 2,
  "limitLines": 100
}
```

Call these objects with `log`, `find`, and `body` respectively. Read each receipt’s `complete`, `withheld`, and `deferredBodies` fields.
