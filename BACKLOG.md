# Swarm Backlog

Items ranked by priority for local (Mac) development workflow.

## P1 — Fix now

## P2 — Should fix

### Silent git failures in critical paths — **Fixed**
- [x] Audited all git operations — categorized 50+ `2>/dev/null` sites as critical vs harmless
- [x] `sync_main()` and `sync_remote()` now warn on failure instead of silent `|| true`
- [x] All clone ops in unstick/bootstrap/resume paths validate exit code and warn on failure
- [x] Entrypoint: orchestrator/reviewer/specialist clones validated (exit 2 on failure, stderr to log)
- [x] Worker `git pull` stderr redirected to log file instead of `/dev/null`
- [x] Replaced inline `git pull` calls with `sync_main` where appropriate

### Auto-fallback to alternate model on 529 overload errors
When workers hit repeated 529 (overloaded) errors, they currently just backoff and retry the same model indefinitely. A smarter approach would detect sustained overload and automatically switch to a fallback model (e.g. opus → sonnet → haiku) until the primary recovers.
- [ ] Detect 529 separately from rate-limit (429) in worker error handling
- [ ] After N consecutive 529s, switch `CLAUDE_MODEL_FLAG` to a fallback model
- [ ] Restore primary model after successful response (or on next container restart)
- [ ] Make fallback chain configurable (e.g. `--fallback-model sonnet`)
- [ ] Consider harness-level detection: if all workers are 529-looping, kill and resume with fallback

### CID file written before container actually starts
`docker run -d` returns immediately. If the container fails to start (bad image, OOM), the `.cid` file already points to a dead container. Next cycle, `check_and_respawn_dead_workers` may unstick tasks unnecessarily.
- [ ] Verify container is running after `docker run -d` before writing `.cid`

### Specialist failures silently ignored
Background `&` + `wait || true` in `run_specialist_sweep` — if a specialist crashes or fails to push, nobody knows.
- [ ] Capture exit codes from `wait`, log warnings on failure

### cmd_kill has no tests — **Fixed**
- [x] Added `tests/test_kill.sh` (6 tests, 13 assertions)
- [x] Covers: kill specific worker, kill all workers, missing pids dir, missing worker, ghost container, no output dir

## P3 — Later (cloud prep)

### Cost/token tracking
No visibility into how many API tokens a swarm run consumed. Useful for budgeting and optimizing task breakdown.
- [ ] Capture claude CLI token usage output per invocation
- [ ] Aggregate and report totals at run completion

### No tests for worker sudo/apt-get capability in Docker
Workers can now `sudo apt-get install` packages at runtime (e.g. xvfb, imagemagick) — but there are no tests verifying this works. A broken sudoers config or missing `sudo` package in the image would cause silent failures where workers skip visual verification steps.
- [ ] Add `tests/test_docker_sudo.sh` — verify `swarm` user can run `sudo apt-get install -y <pkg>` inside a container built from the current Dockerfile
- [ ] Test that a worker entrypoint can install and invoke `xvfb-run` successfully
- [ ] Run as part of CI after any Dockerfile change

### Timeouts on git and claude operations
All git and claude CLI calls have no timeout. A hung network connection blocks the worker forever. Matters more on unreliable cloud networks.
- [ ] Add timeout wrappers around git operations (10-30s)
- [ ] Add timeout on claude CLI invocations (configurable, default 5m)

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

### Parallelize Docker-dependent tests
`test_cleanup.sh` and `test_dead_worker.sh` run sequentially because they share Docker container namespaces. Give each test a fully unique container name prefix (e.g. `swarm-test-${SUITE}-${PID}-${RANDOM}`) so they can run in parallel with the rest.
- [ ] Unique container name prefixes per test
- [ ] Remove sequential exception from `run_tests.sh`

## Done

### Stuck detection with done_count = 0
- [x] Removed `done_count > 0` guard from stuck-state detector — now fires when `pending > 0, active = 0` regardless of done count
- [x] Test: `test_reviewer_loop.sh` — "stuck detection fires with pending > 0, active = 0, done = 0"

### Git clone failure / infinite respawn loop
- [x] Worker entrypoint validates `git clone` success — exits with code 2 on failure, logs `CLONE_FAILED`
- [x] Respawn attempts capped at `MAX_RESPAWNS` (default 5) per worker via `pids/worker-N.respawns` counter
- [x] Counter resets when any task completes (progress = system is healthy)
- [x] Tests: `test_reviewer_loop.sh` — respawn cap + counter reset (3 new tests, total 24)

### Reviewer artifact compliance
- [x] Orchestrator augment mode checks acceptance criteria for required artifacts
- [x] If required artifacts are missing, orchestrator creates a fix task
- [x] Test: `test_quiet_periods.sh` Test 9 — TESTS_FAIL → orchestrator fix task → TESTS_PASS

### Log rotation
- [x] `truncate_log()` in `docker/entrypoint.sh` caps log files after each `run_claude()` call
- [x] Default 10MB cap (`MAX_LOG_SIZE=10485760`); set `MAX_LOG_SIZE=0` to disable
- [x] Truncation keeps the tail (most recent output), prepends a `[log truncated...]` marker
- [x] Cross-platform: `stat -f%z` (macOS) / `stat -c%s` (Linux) with `|| echo 0` fallback
- [x] Tests: `tests/test_log_streaming.sh` (3 new tests, total 16)

### Real-time log streaming for all roles
- [x] `run_claude()` uses `claude -p --output-format stream-json --include-partial-messages` — tokens stream as they arrive, no PTY needed
- [x] `docker/stream_parse.py` parses the JSON stream: `content_block_delta` → log in real-time; `result` text → `CLAUDE_OUTPUT_FILE` for signal grep
- [x] Works cross-platform (macOS + Linux) — no `script` needed, no platform branching
- [x] Validated in real swarm run: byte count grows continuously mid-invocation; silence only during tool execution (expected — no text tokens)
- [x] `./swarm logs <output-dir> [worker-N]` subcommand added (wraps `tail -f`)
- [x] Tests: `tests/test_log_streaming.sh` (12 tests), `tests/test_logs.sh` (6 tests)

### Allow specifying the claude model when launching or resuming
- [x] `--model` flag on `./swarm` and `./swarm resume`
- [x] Stored as `SWARM_MODEL` in `swarm.state`, restored on resume
- [x] Passed to all `docker_run_*` as `MODEL` env var, then `--model` to claude CLI
- [x] Tests: `tests/test_model_flag.sh` (7 tests)

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
- [x] Test was in `test_inject.sh` (deleted with inject deprecation) — test coverage lost, covered by code audit

### Periodic orchestrator + specialist sweeps
- [x] Every N completions (default 6, `RESTRUCTURE_INTERVAL`), orchestrator runs in augment mode + specialist sweep concurrently with workers
- [x] Orchestrator handles: BLOCKED tasks, stale pending task manifests, CLAUDE.md/SPEC.md updates, test failures, gaps
- [x] Reviewer simplified to pure test runner (TESTS_PASS/TESTS_FAIL only) — no restructuring powers
- [x] TESTS_FAIL from reviewer triggers orchestrator immediately (doesn't wait for next interval)
- [x] Stuck state and BLOCKED tasks now handled by orchestrator (not reviewer)
- [x] Tests: `tests/test_quiet_periods.sh` (11 tests), `tests/test_e2e.sh` includes Tests 11–13

### Deprecate inject agent
- [x] Removed `prompts/inject.md`, `run_inject()`, `docker_run_inject()`, `cmd_inject()`
- [x] Resume with guidance now runs orchestrator in augment mode (reads existing codebase, updates SPEC.md, creates new tasks)
- [x] Specialist sweep runs after orchestrator augment (not on plain resume)
- [x] All tests updated: unified_command, log_streaming, model_flag

### Specialist roster refinement
- [x] Added QAEngineer and PerformanceEngineer as default specialists
- [x] Removed DataScientist as default (too domain-specific)
- [x] Sharpened SystemsDesignExpert vs PerformanceEngineer boundary (reliability/correctness vs speed/throughput)

### E2E integration test
- [x] Mock claude does real git operations (claim, complete, push) without API tokens
- [x] 10 scenarios (32 assertions): full lifecycle, crash recovery, log streaming, rate limit, task ordering, resume without prompt, resume with prompt (orchestrator augment + post-augment sweep), specialist parsing, pre-flight sweep, quiet period sweep
- [x] Tests: `tests/test_e2e.sh` (36 tests)
