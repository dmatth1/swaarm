# Swarm Backlog

Items ranked by priority for local (Mac) development workflow.

## P1 — Fix now

### stuck detection skips when done_count = 0
**Bug** · `swarm:796`
The stuck-state detector (pending > 0, active = 0) only fires when at least one task is already done. If workers repeatedly crash before completing any task, the project idles forever with no reviewer triggered and no recovery.
- [ ] Remove or relax the `done_count() -gt 0` guard
- [ ] Add test to `tests/test_reviewer_loop.sh` covering `pending > 0, active = 0, done = 0`

### E2E integration test
No test exercises the full coordination loop end-to-end. Approach: override `docker_run_*` functions to run `bash docker/entrypoint.sh` directly (bypassing Docker), with mock claude scripts that perform the actual git operations (create tasks, claim, complete). Would test orchestrator → worker race → reviewer → ALL_COMPLETE with real git.
- [ ] Implement `tests/test_e2e.sh` with 3 tasks + 2 workers

### Reviewer does not verify task artifact compliance
**Bug** · `prompts/reviewer.md`
The reviewer checks if code compiles and unit tests pass, but does not verify that workers actually produced the artifacts required by task acceptance criteria (e.g. screenshots, test output files, verification reports). Workers can mark tasks DONE while skipping required verification steps. Discovered during ProQ4 run where 11 UI tasks were completed without any Xvfb screenshot evidence despite task descriptions requiring it.
- [ ] Update reviewer prompt to parse acceptance criteria for required artifacts (files, screenshots, test outputs)
- [ ] Reviewer should check `git log` for expected committed files before signaling REVIEW_DONE
- [ ] If required artifacts are missing, reviewer should create a fix task or reject the completion
- [ ] Add test to `tests/test_reviewer_loop.sh` covering artifact compliance check

### Octal parsing bug with zero-padded task numbers
**Bug** · `swarm:458,474`
Bash interprets zero-padded numbers like `008`, `009`, `018` as invalid octal in `[[ ]]` comparisons. Fixed in two places with `$((10#$num))` but should audit all task-number parsing throughout the script.
- [ ] Audit all `grep -o '^[0-9]*'` → `[[ ]]` patterns for octal safety
- [ ] Add test covering task numbers 008, 009, 018, 019, etc.

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
