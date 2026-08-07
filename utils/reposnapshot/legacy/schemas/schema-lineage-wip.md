Phase 2 crawler output          Phase 3 input              Phase 3 output (pruned)
pre-walk-node-graph.schema      ignore-engine-input.schema  ignore-engine-output.schema
─────────────────────────────   ──────────────────────────  ────────────────────────────
NodePath          ──────────►  NodePath          ──────►   NodePath
NodeDepth         ──────────►  NodeDepth         ──────►   NodeDepth
IgnoreFiles       ──────────►  IgnoreFiles       consumed  (absent — processed away)
  └ Source                       └ Source
  └ Globs                        └ Globs
ExecutiveOverrides (root) ────►  ExecutiveOverrides(root)  (absent — compiled away)
Files             ──────────►  (ABSENT — stripped)         (absent — Phase 4 adds these)
                                                            CompiledIgnore  ◄── added
                                                              └ Positives
                                                              └ Exceptions
                                                            ExecutiveOverride ◄── added
