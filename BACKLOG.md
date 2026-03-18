# Swarm Backlog

## P2 — Should fix

### `./swarm sweep` subcommand for ad-hoc specialist runs
No way to run a single specialist or a full sweep without resuming the entire swarm. Useful for: running ProjectManager to consolidate after manual task edits, running QAEngineer to audit test coverage, or re-running a failed specialist.
- [ ] `./swarm sweep <output-dir>` — run all specialists (same as periodic sweep)
- [ ] `./swarm sweep <output-dir> --specialist ProjectManager` — run a single specialist by name
- [ ] Reads specialist roster from the project's SPEC.md `## Specialists` section
- [ ] ProjectManager always runs last (after other named specialists if multiple specified)

### Auto-fallback on 529 overload
Workers backoff and retry the same model indefinitely on 529. Should detect sustained overload and switch to a fallback model (e.g. opus → sonnet).
- [ ] Detect 529 separately from rate-limit (429)
- [ ] After N consecutive 529s, switch to fallback model
- [ ] Make fallback chain configurable (`--fallback-model sonnet`)

### Test environment should match production (Docker)
Tests source `entrypoint.sh` directly on macOS, but production runs inside Docker (Linux). Code paths like `timeout` need conditional fallbacks, and the actual production path is never tested.
- Option A: Run entrypoint-dependent tests inside Docker containers
- Option B: Require GNU coreutils on macOS as a dev dependency

## P3 — Later

### Cost/token tracking
No visibility into API token spend per run.
- [ ] Capture token usage from stream-json `result` events in `stream_parse.py`
- [ ] Aggregate and report totals at run completion

### Post-mortem report
No summary at run completion. Hard to tune future runs or understand failures.
- [ ] Generate report: total time, tasks completed, test failures, specialist findings, respawn events, rate-limit backoffs

### Dry-run mode
No way to preview orchestration before burning API credits.
- [ ] `./swarm --dry-run "build X"` — run orchestrator only, show task DAG, exit without spawning workers

### Configurable specialist roster
6 specialists always run regardless of project complexity, wasting API calls on simple projects.
- [ ] `--specialists "PM,QA"` flag to select which specialists run

### Parallelize Docker-dependent tests
`test_cleanup.sh`, `test_dead_worker.sh`, and `test_kill.sh` run sequentially (shared container namespaces).
- [ ] Unique container name prefixes per test suite
- [ ] Remove sequential exception from `run_tests.sh`

## P4 — Future ideas

### Task dependency graph visualization
- [ ] `./swarm graph <dir>` subcommand outputting DOT or Mermaid diagram
- [ ] Color-code nodes by state (pending/active/done/blocked)

### Worker task affinity
Worker that did `003-setup-database` has packages/context for `007-add-migrations`.
- [ ] Lightweight affinity: prefer workers who completed prerequisite tasks

### Incremental test running
Reviewer always runs full test suite. Slow for large projects (10+ min suites).
- [ ] Detect which test files cover changed modules
- [ ] Run only related tests in reviewer, full suite on final drain

### Multi-repo coordination
Swarm operates on a single repo. Many real projects span frontend + backend + infra.
- [ ] Support `--mount` for additional repos workers can commit to

### Agent-assisted harness (hybrid architecture)
Keep bash for the tight event loop but invoke a Claude agent for judgment calls (OOM recovery, model routing, task rebalancing).
- [ ] Define event types that trigger agent consultation
- [ ] Agent receives context, returns structured action; bash executes
- [ ] Model routing: agent picks haiku for simple tasks, opus for complex ones
