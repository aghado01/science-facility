Logistics side, stripped down.

### Minimal manual setup

```bash
# new session, first pane = PLAN (or lead)
tmux new-session -s agents -n table -c ~/project

# split into stage panes
tmux split-window -h -t agents:table -c ~/project   # WORK
tmux split-window -v -t agents:table.1 -c ~/project # REVIEW (bottom of right)

# optional: equalize
tmux select-layout -t agents:table tiled
# or: main-vertical  (lead wide, others stacked)

# start Claude in each pane
tmux send-keys -t agents:table.0 'claude' Enter
tmux send-keys -t agents:table.1 'claude' Enter
tmux send-keys -t agents:table.2 'claude' Enter
```

Attach: `tmux attach -t agents`.  
Navigate: prefix + arrows (or click if mouse on). Zoom one pane: prefix + `z`.

### Declarative (tmuxinator-style)

YAML defines windows/panes once; one command boots the room:

```yaml
name: agents
root: ~/project
windows:
  - table:
      layout: main-vertical
      panes:
        - claude          # PLAN / lead
        - claude          # WORK
        - claude          # REVIEW
```

`tmuxinator start agents` → session + layout + processes already running.

### Claude Agent Teams path

You don’t split by hand:

1. `tmux new -s team`
2. Inside: `claude` with agent teams + `teammateMode: tmux` (or `auto` when already in tmux)
3. Ask for a team → Claude uses `split-window` / `send-keys` itself; each teammate lands in its own pane

Lead stays in the original pane; teammates appear as new panes.

### psmux angle

Same geometry as tmux (sessions / windows / panes, `send-keys`, `capture-pane`). Differences are usually:

- Windows-friendly / different binary name  
- Sometimes auto env for Claude teams (`TMUX`-compatible detection so Claude’s TmuxBackend still spawns panes)

Logistics stay: create session → split or let the lead split → one agent process per pane → you attach and supervise.

### Baton mechanics (still logistics)

Handoff is not magic — it’s one of:

```bash
# type into another pane
tmux send-keys -t agents:table.1 'Implement the plan in plans/auth.md' Enter

# or capture then send
tmux capture-pane -t agents:table.0 -p -S -50 > /tmp/plan-tail.txt
# then feed that path/content into the next pane’s prompt
```

Or a small wrapper (`agent-handoff PLAN WORK`) that focuses the target pane and pastes a template + artifact path.

**Summary:** session = room, pane = seat, `send-keys` = baton, attach = peanut gallery. psmux doesn’t change that model; it only changes the multiplexer binary and Windows ergonomics.