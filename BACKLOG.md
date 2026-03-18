# Swarm Backlog

## P2 — Should fix

### Auto-fallback on 529 overload
Harness log check (Step 5) already detects 529 patterns. Currently just suggests switching model — should auto-act.
- [ ] When harness sees repeated 529s in worker logs, kill worker and respawn with fallback model
- [ ] Document fallback chain in harness-state.json (e.g. `"model_fallback": ["opus", "sonnet"]`)

## P3 — Later (cloud prep)

### Cost/token tracking
No visibility into API token spend per run.
- [ ] Capture token usage from stream-json `result` events in `stream_parse.py`
- [ ] Aggregate and report totals at run completion

## P4 — Ideas

### Task dependency graph visualization
- [ ] Agent can generate DOT/Mermaid diagram of task DAG on request

### Worker task affinity
Workers get `MODEL` and identity at container start — can't reassign per-task. Affinity would require the harness to track which worker did which prerequisite and route tasks accordingly, but workers self-select tasks from the queue.
- [ ] Explore: harness hints preferred worker in task file, worker prompt checks hint before claiming

### Incremental test running
Reviewer behavior lives in `prompts/reviewer.md`, independent of harness architecture. Still relevant.
- [ ] Reviewer detects changed files, runs only related tests
- [ ] Full suite on final drain only
