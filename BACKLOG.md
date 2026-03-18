# Swarm Backlog

## P2 — Should fix

### Orchestrator skips visual testing despite explicit guidance
The orchestrator was told to install Xvfb and test the UI visually before creating tasks (Step 0). It skipped this entirely, said "Xvfb unavailable in this container" and fell back to code review — despite having sudo access. Workers have the same environment and successfully install Xvfb. The orchestrator prompt guidance needs to be stronger: "You MUST run sudo apt-get install -y xvfb FIRST. Do not skip. Do not claim it's unavailable."
- [ ] Add explicit "do not skip, you have sudo" language to harness.md orchestrator guidance
- [ ] Consider adding Xvfb to the Dockerfile so agents don't need to install it at all
- [ ] Or add a pre-install step in entrypoint.sh for display tools when VISUAL_TESTING=true env var is set

## P3 — Later (cloud prep)

### Cost/token tracking
No visibility into API token spend per run.
- [ ] Capture token usage from stream-json `result` events in `stream_parse.py`
- [ ] Aggregate and report totals at run completion

## P4 — Ideas
