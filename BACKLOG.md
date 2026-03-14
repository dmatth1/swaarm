# Swarm Backlog

## Bugs

### stuck detection skips when done_count = 0
**File:** `swarm:796`
The stuck-state detector (pending > 0, active = 0) only fires when at least one task is already done. If workers repeatedly crash before completing any task, the project idles forever with no reviewer triggered and no recovery.
- [ ] Remove or relax the `done_count() -gt 0` guard
- [ ] Add test to `tests/test_reviewer_loop.sh` covering `pending > 0, active = 0, done = 0`

## Missing Tests

### cmd_kill has no tests
`cmd_kill` (swarm:178) is completely untested. Covers: kill specific worker by ID, kill all workers, missing pids dir error, docker stop/rm failures.
- [ ] Add `tests/test_kill.sh`

## Features

### E2E integration test
No test exercises the full coordination loop end-to-end. Approach: override `docker_run_*` functions to run `bash docker/entrypoint.sh` directly (bypassing Docker), with mock claude scripts that perform the actual git operations (create tasks, claim, complete). Would test orchestrator → worker race → reviewer → ALL_COMPLETE with real git.
- [ ] Implement `tests/test_e2e.sh` with 3 tasks + 2 workers
