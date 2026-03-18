# Swarm Backlog

## P2 — Should fix

### Test environment should match production (Docker)
Tests source `entrypoint.sh` directly on macOS, but production runs inside Docker (Linux). This means code paths like `timeout` need a conditional fallback for macOS, and the actual production code path is never tested.
- Option A: Run entrypoint-dependent tests inside Docker containers — test env literally is production env
- Option B: Require GNU coreutils on macOS (`brew install coreutils`) as a dev dependency, remove the conditional fallback

### Orchestrator should consolidate expensive builds into single tasks — **Done**
- [x] Added "Consolidate expensive builds" rule to `prompts/orchestrator.md` with `artifact:<path>` syntax
- [x] Extended `## Produces` / `## Consumes` in `prompts/task-format.md` to support `artifact:<path>` entries
- [x] Worker prompt (Step 7) checks consumed artifacts exist on disk; emits `NO_TASKS` if missing
- [x] ProjectManager specialist: added build duplication check (flag 3+ tasks building same binary)

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

## P4 — App review ideas

### Task dependency graph visualization
No way to see the task DAG at a glance. Mental tracing of `Dependencies: 001, 003` across files is tedious for large runs.
- [ ] `./swarm graph <dir>` subcommand outputting DOT or Mermaid diagram
- [ ] Color-code nodes by state (pending/active/done/blocked)

### Configurable specialist roster
6 specialists always run regardless of project complexity, wasting API calls on simple projects.
- [ ] `--specialists "PM,QA"` flag to select which specialists run
- [ ] Or read from `.swarmrc` config file

### Reviewed tasks cleanup on augment
`reviewed.list` persists forever. If orchestrator creates new tasks with recycled numbers, they skip review.
- [ ] Clear entries for tasks that get re-created during augment

### Multi-repo coordination
Swarm operates on a single repo. Many real projects span frontend + backend + infra.
- [ ] Support `--mount` for additional repos workers can commit to

### Incremental test running
Reviewer always runs full test suite. Slow for large projects (10+ min suites).
- [ ] Detect which test files cover changed modules
- [ ] Run only related tests in reviewer, full suite on final drain

### Worker task affinity
All workers are identical. Worker that did `003-setup-database` has packages/context for `007-add-migrations`.
- [ ] Lightweight affinity: prefer workers who completed prerequisite tasks

### Post-mortem report
No summary at run completion. Hard to tune future runs or understand failures.
- [ ] Generate report: total time, tasks completed, test failures, specialist findings, respawn events, rate-limit backoffs

### Dry-run mode
No way to preview orchestration before burning API credits.
- [ ] `./swarm --dry-run "build X"` — run orchestrator only, show task DAG, exit without spawning workers
