# Swarm Backlog

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
