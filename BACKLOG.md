# Swarm Backlog

## P1 — High impact

## P2 — Should fix

### Monitoring loop interval should adapt to long-running containers
1-minute polling is right when workers are completing tasks frequently. It's wrong when a reviewer is doing a 25-minute build — generates 25 no-op cycles with zero useful signal.
- [ ] After launching a reviewer or specialist sweep, log `last_long_op_started_at` in harness-state.json
- [ ] In harness.md monitoring guidance: if a reviewer/specialist was launched within the last 10 minutes and log is still at header size, skip detailed checks and just push to remote
- [ ] Or: use `/loop 5m` when entering final drain instead of 1m

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

## P4 — Ideas

### Use EXTRA_GUIDANCE more aggressively for stuck workers
EXTRA_GUIDANCE exists to feed error context back to struggling workers but was used zero times in ProQ4-Dup. Workers self-corrected, but the mechanism should be a first-line tool.
- [ ] Update harness.md: when a worker log shows repeated errors on the same task, read the last 200 lines and respawn with the error text in EXTRA_GUIDANCE before escalating
- [ ] Add an example to the EXTRA_GUIDANCE section in harness.md showing pasting actual error output
