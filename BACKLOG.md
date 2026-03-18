# Swarm Backlog

## P2 — Should fix

### Test the agent harness end-to-end
The agent harness (`prompts/harness.md` + `/loop`) replaces the bash harness. It needs real-world validation.
- [ ] Run a small project (5-10 tasks) fully managed by the agent harness
- [ ] Verify: new run, resume, specialist sweeps, final drain all work
- [ ] Verify: context compaction doesn't break monitoring (state file re-read)

### Auto-fallback on 529 overload
Workers backoff and retry the same model indefinitely on 529. Should detect sustained overload and switch to a fallback model (e.g. opus → sonnet).
- [ ] Detect 529 separately from rate-limit (429)
- [ ] After N consecutive 529s, switch to fallback model
- [ ] Make fallback chain configurable

## P3 — Later (cloud prep)

### Cost/token tracking
No visibility into API token spend per run.
- [ ] Capture token usage from stream-json `result` events in `stream_parse.py`
- [ ] Aggregate and report totals at run completion

## P4 — Ideas

### Task dependency graph visualization
- [ ] Agent can generate DOT/Mermaid diagram of task DAG on request

### Post-mortem report
- [ ] Agent generates summary at run completion: tasks, time, decisions, failures

### Worker task affinity
- [ ] Prefer workers who completed prerequisite tasks (shared filesystem state)

### Incremental test running
- [ ] Reviewer runs only related tests, full suite on final drain
