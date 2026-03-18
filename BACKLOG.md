# Swarm Backlog

## P1 — Fix now

### Dead worker detection improvements — **Partial fix**
- [x] Added `sync_main` inside `check_and_respawn_dead_workers` before checking active tasks — ensures MAIN_DIR has latest claims from workers that pushed before dying
- [x] Added log line when dead worker detected (`Worker N is dead (status: gone)`)
- [x] Container-not-found already handled correctly (`|| running="gone"`)
- [ ] Test: worker container removed (not stopped) → harness detects and respawns
- [ ] Root cause of original incident still unclear — may be a timing issue where workers die between `sync_main` and claim detection

## P2 — Should fix

### `./swarm sweep` subcommand — **Done**
- [x] `./swarm sweep <output-dir>` — full sweep (all specialists parallel, PM last)
- [x] `./swarm sweep <output-dir> --specialist NAME` — single specialist, PM consolidation after
- [x] `./swarm sweep <output-dir> --specialist ProjectManager` — PM solo (no auto-consolidation)
- [x] Reads roster from project's SPEC.md, supports `--model` override

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
