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
