Need to codify the temp artifacts and IR filepath writing conventions

- essentially just need to implement a default behavior along the lines of `chat-export/{project-slug}/{run-stamp}/{sessionid}/**`
- this will likely live under `~/.claude/tmp/`
- may want slightly different behavior for batch exports with a convention that reflects provenance
  - different semantics for a batch of specific session ids, which may span projects, vs a project targeted batch export
- want to incorporate some utilities searching .claude/projects/\*\* to find specific conversations based on glob patterns
