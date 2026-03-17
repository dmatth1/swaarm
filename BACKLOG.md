# Swarm Backlog

Items ranked by priority for local (Mac) development workflow.

## P1 — Fix now

### Worker logs don't stream during claude session
**Bug** · `docker/entrypoint.sh` — **Fix implemented, needs real-world validation**
Worker logs show the startup header then go silent for 15-30 min until claude finishes. Root cause: `claude -p` block-buffers to pipes, and `output=$(...)` re-buffers even with a PTY.
**Fix**: `run_claude()` uses `script` for PTY + writes to `CLAUDE_OUTPUT_FILE` via `tee` (no subshell capture). Worker greps the file for signals/rate-limit after completion. Log file streams in real-time.
- [x] `stdbuf -oL` — doesn't work (Node.js doesn't use C stdio)
- [x] `script -qfc` PTY — works but `output=$(...)` re-buffers
- [x] Refactored: removed `output=$(...)`, write to temp file, grep for signals
- [ ] Validate in real swarm run

### stuck detection skips when done_count = 0
**Bug** · `swarm:796`
The stuck-state detector (pending > 0, active = 0) only fires when at least one task is already done. If workers repeatedly crash before completing any task, the project idles forever with no reviewer triggered and no recovery.
- [ ] Remove or relax the `done_count() -gt 0` guard
- [ ] Add test to `tests/test_reviewer_loop.sh` covering `pending > 0, active = 0, done = 0`


### Reviewer does not verify task artifact compliance
**Bug** · `prompts/reviewer.md` — **Fixed (prompt change)**
The reviewer checks if code compiles and unit tests pass, but does not verify that workers actually produced the artifacts required by task acceptance criteria (e.g. screenshots, test output files, verification reports). Workers can mark tasks DONE while skipping required verification steps. Discovered during ProQ4 run where 11 UI tasks were completed without any Xvfb screenshot evidence despite task descriptions requiring it.
- [x] Update reviewer prompt to parse acceptance criteria for required artifacts (files, screenshots, test outputs)
- [x] Reviewer checks `git log --name-only` for expected committed files
- [x] If required artifacts are missing, reviewer creates a fix task
- [x] ALL_COMPLETE gated on all required artifacts being committed
- [ ] Add test to `tests/test_reviewer_loop.sh` covering artifact compliance check


## P2 — Should fix

### cmd_kill has no tests
`cmd_kill` (swarm:220) is completely untested. Covers: kill specific worker by ID, kill all workers, missing pids dir error, docker stop/rm failures.
- [ ] Add `tests/test_kill.sh`

### Silent git failures in critical paths
Git clone/push/pull operations throughout the script are silenced with `2>/dev/null` or `|| true`. When they fail (e.g. during unstick or respawn), tasks stay stuck with no error message.
- [ ] Audit all git operations for silent failure
- [ ] Add error checking on critical paths (unstick, respawn, bootstrap)
- [ ] Log failures instead of swallowing them

### Cost/token tracking
No visibility into how many API tokens a swarm run consumed. Useful for budgeting and optimizing task breakdown.
- [ ] Capture claude CLI token usage output per invocation
- [ ] Aggregate and report totals at run completion

### Git clone failure causes infinite respawn loop
If a worker's initial `git clone` fails (repo corruption, disk full), the worker exits, `check_and_respawn_dead_workers()` sees the stuck task and respawns — which also fails. Infinite loop.
- [ ] Validate git clone success in entrypoint.sh before entering worker loop
- [ ] Cap respawn attempts per worker

## P3 — Later (cloud prep)

### Timeouts on git and claude operations
All git and claude CLI calls have no timeout. A hung network connection blocks the worker forever. Matters more on unreliable cloud networks.
- [ ] Add timeout wrappers around git operations (10-30s)
- [ ] Add timeout on claude CLI invocations (configurable, default 5m)

### Log rotation
Worker logs append indefinitely with no rotation. Long runs on a server can fill disk.
- [ ] Implement log rotation or size cap per worker log

### Docker memory limits on containers
No memory limits on worker containers. A worker generating OOM-inducing code can take down the host.
- [ ] Add `--memory` flag to docker run calls (configurable, default 4G)

### `run_with_review()` total timeout
The review loop runs indefinitely until `ALL_COMPLETE`. No safety valve if something goes wrong.
- [ ] Add optional `--timeout` flag for max wall-clock time
- [ ] Default to no limit (current behavior) for backwards compat

### Structured logging
All logging is line-based text. Machine-readable events would enable automation and monitoring.
- [ ] Consider JSON lines format for worker/reviewer events
- [ ] Add timestamps and severity levels

## Done

### Stream worker logs to a centralized source
- [x] All roles (worker, orchestrator, reviewer, specialist, inject) use `tee -a` for real-time log streaming
- [x] `./swarm logs <output-dir> [worker-N]` subcommand added (wraps `tail -f`)
- [x] Tests: `tests/test_log_streaming.sh` (11 tests), `tests/test_logs.sh` (6 tests)

### Allow specifying the claude model when launching or resuming
- [x] `--model` flag on `./swarm` and `./swarm resume`
- [x] Stored as `SWARM_MODEL` in `swarm.state`, restored on resume
- [x] Passed to all `docker_run_*` as `MODEL` env var, then `--model` to claude CLI
- [x] Tests: `tests/test_model_flag.sh` (12 tests)

### Task-scoped file manifests
- [x] Orchestrator includes `## Relevant Files` section in task file format (Read/Modify/Create/Skip prefixes with annotations)
- [x] Worker prompt adds Step 6: Load Relevant Files between claim and interface loading
- [x] Reviewer updates `## Relevant Files` on pending tasks after each completion
- [x] Framed as hints, not hard constraints — workers can explore beyond the list if needed

### Use CLAUDE.md as a living project index to reduce worker orientation cost
- [x] Orchestrator creates initial `CLAUDE.md` alongside SPEC.md (step 3 in prompt): project structure, tech stack, build commands, module map
- [x] Reviewer updates `CLAUDE.md` after each task completion (step 6 in prompt): new files, changed patterns, updated structure
- [x] 200-line cap enforced in both prompts — reviewer compacts when it grows
- [x] Worker prompt notes CLAUDE.md is auto-loaded by Claude Code — no explicit read needed
- [x] Clear separation: CLAUDE.md = orientation (what exists, how to build), SPEC.md = contracts (interfaces, criteria)

### Octal parsing bug with zero-padded task numbers
- [x] Audited all 3 `grep -o '^[0-9]*'` → `[[ ]]` patterns — all use `$((10#$num))`
- [x] Test: `tests/test_inject.sh` test 5 covers task numbers 008, 009, 018, 019

### Quiet periods for reviewer/specialist sweeps
- [x] Every N completions (default 10, `QUIET_PERIOD_INTERVAL`), pause workers via `docker pause`
- [x] `wait_for_active_drain()` waits up to 10m for active tasks to complete
- [x] Full reviewer (`--full-review--` mode) runs with restructuring powers during quiet period
- [x] Specialist sweep runs during quiet period (exclusive repo access)
- [x] Workers resume via `docker unpause` after quiet period
- [x] Per-task reviews use `quick` mode (tests only, skip CLAUDE.md/manifest updates and task restructuring)
- [x] Reviewer prompt supports `{{REVIEW_MODE}}` (quick/full) and `--full-review--` COMPLETED_TASK
- [x] Tests: `tests/test_quiet_periods.sh` (16 tests)

### E2E integration test
- [x] Mock claude does real git operations (claim, complete, push) without API tokens
- [x] 8 scenarios: full lifecycle (3 tasks, 2 workers), git conflict resolution, crash recovery, inject agent, log streaming, review loop with real worker entrypoint, rate limit backoff, task ordering
- [x] Tests: `tests/test_e2e.sh` (26 tests)
