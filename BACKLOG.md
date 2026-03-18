# Swarm Backlog

## P2 — Should fix

### Specialists should audit and create tasks, not fix directly
Specialists currently make direct code changes (refactoring, adding tests, fixing bugs) during sweeps. This causes: merge conflicts with workers running in parallel, bypasses the task→review quality gate, and a hung specialist (e.g. deadlocked JUCE test binary) blocks the entire pipeline before workers start. Observed: AudioDSPSpecialist deadlocked for 52 min on a `build_tests.sh run` tool call, blocking all 5 workers from spawning.
- [ ] Update all specialist role descriptions in `prompts/orchestrator.md` to audit-only: identify issues, create tasks in `tasks/pending/`, do not write code
- [ ] Allow small surgical fixes (one-line comments, named constants) but no build/test cycles
- [ ] Remove "Fix what you find directly" / "Refactor directly" language from specialist prompts

### Timeout on claude CLI invocations — **Done**
- [x] `run_claude()` wraps `claude` with `timeout $CLAUDE_TIMEOUT` (default 1800s / 30m)
- [x] On timeout (exit 124), logs `[timeout] claude invocation killed after Ns`
- [x] Graceful fallback: skips `timeout` when not available (macOS — tests run on macOS, Docker has GNU coreutils)
- [x] Covers all roles: orchestrator, worker, reviewer, specialist

### Auto-fallback on 529 overload
Workers backoff and retry the same model indefinitely on 529. Should detect sustained overload and switch to a fallback model (e.g. opus → sonnet).
- [ ] Detect 529 separately from rate-limit (429)
- [ ] After N consecutive 529s, switch to fallback model
- [ ] Make fallback chain configurable (`--fallback-model sonnet`)

## P3 — Later (cloud prep)

### Cost/token tracking
No visibility into API token spend per run.
- [ ] Capture token usage from stream-json `result` events in `stream_parse.py`
- [ ] Aggregate and report totals at run completion

### Timeouts on git operations
No timeouts on git calls. Hung network blocks the worker forever.
- [ ] Timeout wrappers around git operations (10-30s)

### Docker memory limits
No memory limits on worker containers. OOM-inducing code can take down the host.
- [ ] Add `--memory` flag to docker run calls (configurable, default 4G)

### `run_with_review()` total timeout
Review loop runs indefinitely. No safety valve.
- [ ] Add optional `--timeout` flag for max wall-clock time

### Parallelize Docker-dependent tests
`test_cleanup.sh`, `test_dead_worker.sh`, and `test_kill.sh` run sequentially (shared container namespaces).
- [ ] Unique container name prefixes per test suite
- [ ] Remove sequential exception from `run_tests.sh`
