# Swarm Backlog

## P1 — High impact

### Enforce specialist sweep before final reviewer
Harness must always run the specialist sweep before the final reviewer. Skipping it risks declaring completion while real issues exist (confirmed: SP crash persisted past TESTS_PASS in run swarm-20260320-110046).
- [ ] Update `harness.md` decision logic: specialist sweep is mandatory before running `COMPLETED_TASK=--final--` reviewer
- [ ] Add a `specialist_sweep_before_final_reviewer` flag to harness-state.json, set to true only after the sweep runs
- [ ] Reviewer step: check flag is true; if not, run sweep first

### Use harness-state.json as primary memory; clear rather than compact context
Context compaction discards history and can cause the harness to lose track of what has been done, leading to skipped steps (e.g. specialist sweep). harness-state.json should be the authoritative source of truth.
- [ ] Update monitoring instructions in harness.md: always re-read harness-state.json at the start of each cycle to reconstruct what phase the run is in
- [ ] Prefer clearing context (start fresh) over compaction when context is large, since harness-state.json has the full history
- [ ] Add explicit "phase" field to harness-state.json (e.g. `"phase": "workers_running" | "specialist_sweep" | "final_review" | "complete"`) so the harness can resume correctly after a clear

## P3 — Later (cloud prep)

### Cost/token tracking
No visibility into API token spend per run.
- [ ] Capture token usage from stream-json `result` events in `stream_parse.py`
- [ ] Aggregate and report totals at run completion

### Pre-configured model fallback
When a model hits 529 overload, the harness detects it reactively after one monitoring cycle. A pre-configured fallback avoids the delay.
- [ ] Add optional `fallback_model` field to harness-state.json
- [ ] Update harness.md: if workers hit 529/overload errors, respawn with `fallback_model` before informing the user
- [ ] Log model switches in the `decisions` array
