# Swarm Backlog

## P2 — Should fix

### `--no-sweep` flag to skip pre-flight and post-augment specialist sweeps
Pre-flight and post-augment specialist sweeps can be slow. Add a flag to skip them while keeping periodic sweeps (which run during normal operation and catch issues over time).
- [ ] Add `--no-sweep` CLI flag (default: false — all sweeps run as normal)
- [ ] Store in `swarm.state` as `SWARM_NO_SWEEP` for resume
- [ ] Skip pre-flight and post-augment `run_specialist_sweep` calls when set; keep periodic sweeps
- [ ] Update `--help` and CLAUDE.md

### Auto-fallback on 529 overload
Workers backoff and retry the same model indefinitely on 529. Should detect sustained overload and switch to a fallback model (e.g. opus → sonnet).
- [ ] Detect 529 separately from rate-limit (429)
- [ ] After N consecutive 529s, switch to fallback model
- [ ] Make fallback chain configurable (`--fallback-model sonnet`)

### CID file written before container starts
`docker run -d` returns immediately. If the container fails to start, the `.cid` file points to a dead container and `check_and_respawn_dead_workers` may unstick tasks unnecessarily.
- [ ] Verify container is running after `docker run -d` before writing `.cid`

### Specialist failures silently ignored
`run_specialist_sweep` uses `&` + `wait || true` — crashed specialists are invisible.
- [ ] Capture exit codes from `wait`, log warnings on failure

## P3 — Later (cloud prep)

### Cost/token tracking
No visibility into API token spend per run.
- [ ] Capture token usage from stream-json `result` events in `stream_parse.py`
- [ ] Aggregate and report totals at run completion

### Timeouts on git and claude operations
No timeouts on any external call. Hung network blocks the worker forever.
- [ ] Timeout wrappers around git operations (10-30s)
- [ ] Timeout on claude CLI invocations (configurable, default 5m)

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
