# Swarm Backlog

## P1 — High impact

### Log heartbeat during Claude invocations
`stream_parse.py` only logs text tokens — tool calls are silent. This makes it impossible to distinguish "JUCE build in progress" from "container hung." In ProQ4-Dup, 25 monitoring cycles fired with the log frozen at 57 bytes.
- [ ] In `run_claude()`, spawn a background loop that writes `[heartbeat $(date)]` to the log file every 60s while the claude pipeline is running, then kill it when done
- [ ] Update harness.md: treat absence of heartbeat (not just log growth) as the hung indicator

## P2 — Should fix

### Orchestrator skips visual testing despite explicit guidance
The orchestrator was told to install Xvfb and test the UI visually before creating tasks (Step 0). It skipped this entirely, said "Xvfb unavailable in this container" and fell back to code review — despite having sudo access. Workers have the same environment and successfully install Xvfb. The orchestrator prompt guidance needs to be stronger: "You MUST run sudo apt-get install -y xvfb FIRST. Do not skip. Do not claim it's unavailable."
- [ ] Add explicit "do not skip, you have sudo" language to harness.md orchestrator guidance
- [ ] Consider adding Xvfb to the Dockerfile so agents don't need to install it at all
- [ ] Or add a pre-install step in entrypoint.sh for display tools when VISUAL_TESTING=true env var is set

### Monitoring loop interval should adapt to long-running containers
1-minute polling is right when workers are completing tasks frequently. It's wrong when a reviewer is doing a 25-minute build — generates 25 no-op cycles with zero useful signal.
- [ ] After launching a reviewer or specialist sweep, log `last_long_op_started_at` in harness-state.json
- [ ] In harness.md monitoring guidance: if a reviewer/specialist was launched within the last 10 minutes and log is still at header size, skip detailed checks and just push to remote
- [ ] Or: use `/loop 5m` when entering final drain instead of 1m

### Pre-sweep worker validation
The final3 specialist sweep failed because workers were still alive doing final git operations even though `tasks/active/` appeared empty. All 7 specialists got `FATAL: git clone failed`.
- [ ] Update harness.md: before any specialist sweep, explicitly run `docker ps --filter name=swarm-<run-id>-worker` and confirm it returns empty — not just that `tasks/active/` is empty
- [ ] Add this check to the Specialist Sweep section of harness.md as a mandatory pre-flight step

### Task number collisions from specialist-created tasks
Multiple tasks ended up sharing the same number prefix (140-*, 141-*, 157-*, etc.) because specialists created tasks mid-run and PM renumbering didn't always cleanly increment. The `tasks/done/` directory had five different tasks all numbered 140.
- [ ] Update task-format.md and PM prompt: "All tasks must have globally unique numbers. Number new tasks sequentially from NEXT_TASK_NUM. Never assign the same number to two tasks."
- [ ] PM prompt should explicitly say: scan existing pending/active/done for the highest number before assigning new ones

### Early specialist sweeps for complex projects
Specialists found serious threading data races, audio thread violations, and wrong filter math — but only during final sweeps, after workers had already built more code on top of the bugs. Earlier sweeps would catch these when they're cheaper to fix.
- [ ] Update harness.md decision logic: "for projects with complex concurrent architecture (C++, multi-threaded, audio/realtime), run a specialist sweep at ~30% and ~60% completion in addition to the periodic sweep cadence"

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
