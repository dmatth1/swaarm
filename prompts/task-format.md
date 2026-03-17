# Task Creation Guide

This section applies to any agent creating task files (orchestrator, inject, reviewer, specialist).

## Task File Format

```markdown
# Task NNN: Task Name

## Description
What needs to be done. Be specific.

## Produces
Implements: `InterfaceName`

## Consumes
InterfaceName
AnotherInterface

## Relevant Files
Read: `path/to/dependency.py` — why this file matters for this task
Read: `path/to/integration_point.py` — what the worker needs from it
Modify: `path/to/existing.py` — what changes are needed
Create: `path/to/new_file.py` — what this file will contain
Skip: `path/to/unrelated/` — not needed for this task

## Acceptance Criteria
- [ ] Run: `<exact command>` → Expected: `<exact output or behavior>`
- [ ] Run: `<exact command>` → Expected: `<exact output or behavior>`

## Tests
- Unit: `tests/test_foo.py::test_bar` — what this test validates
- Unit: `tests/test_foo.py::test_baz_invalid_input` — edge case description
- Integration: `tests/test_foo_integration.py::test_foo_wires_with_bar` — what boundary this validates
None (for setup/infra tasks that produce no testable logic)

## Technical Details
- Function signatures, API routes, data schemas
- Commands to run (e.g., `pip install X`, `go mod init`)
- Any specific implementation requirements

## Dependencies
None | Requires task 001 | Requires tasks 001, 002
```

## Task Granularity

Create as many tasks as the project requires — there is no cap. Lean toward **granular, composable tasks** over large monolithic ones. A task that does one thing well is better than a task that does three things. Granular tasks parallelize better, fail in isolation, and are easier for workers to complete correctly.

The right size for a task is one where a worker can complete it by reading SPEC.md (up to `## Interfaces`) plus the task file plus only its `## Relevant Files` and listed interface definitions. If a task would require understanding more than that, split it.

## Task Field Rules

**`## Produces`:**
- Names the interface from SPEC.md `## Interfaces` that this task implements
- Write `None` (bare word, no backticks, on the line after the header) if this task produces no named interface — e.g., project setup, testing tasks, integration tasks

**`## Consumes`:**
- Lists interface names from SPEC.md `## Interfaces`, one per line
- Write `None` (bare word, no backticks, on the line after the header) if this task has no interface dependencies
- Workers read these interface definitions from SPEC.md after claiming the task

**`## Tests`:**
- Specify exact test file paths and test function names the worker must write
- Use prefixes: `Unit:` for isolated logic, `Integration:` for cross-component boundaries, `E2E:` for full-stack flows
- Write `None` only for tasks that produce no testable logic (project setup, test infrastructure itself, documentation)
- Be specific enough that the worker knows exactly what scenarios to cover — don't write "add tests"; write what the tests must verify
- Integration tasks and the final verification task should include E2E criteria

**`## Relevant Files`:**
- List every file the worker should read, modify, or create — with a brief annotation explaining why
- Prefixes: `Read:` (context only), `Modify:` (change existing file), `Create:` (new file), `Skip:` (explicitly irrelevant — use for large directories workers might waste time exploring)
- This is a hint, not a hard constraint — workers may explore beyond the list if needed, but most tasks should not require it
- For setup tasks (001, 002), this section can be minimal since there's no existing codebase yet
- Keep the list focused: 3–8 entries is typical. If you need more than 10, the task may be too large — split it

**`## Acceptance Criteria`:**
- Every criterion must be expressed as a concrete, runnable command and its expected output
- Format: `Run: <exact shell command in project directory>` → `Expected: <exact output, exit code, or observable behavior>`
- Examples:
  - `Run: python -m pytest tests/test_auth.py -q` → `Expected: all tests pass, exit 0`
  - `Run: curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health` → `Expected: 200`
  - `Run: python -c "from src.db import get_session; print('ok')"` → `Expected: ok`
- Do NOT write criteria like "function exists" or "code is correct" — those are not verifiable

## Dependencies

- **No circular dependencies** — trace every dependency chain. If task A → B → C → A, you have a deadlock.
- **Avoid spurious dependencies** — only add a dependency when the prior task's output is literally required on disk to proceed. Ask: "Can a worker write the code for this task without the prior task's files existing?" If yes, remove the dependency.
- **Verify parallelism** — if nearly all tasks form a single chain, reconsider whether those serial dependencies are truly required.

## Integration Tasks

When a downstream task would `## Consumes` 3 or more interfaces, insert an integration task before it:

1. Create an integration task (e.g., `050-integration-data-layer.md`) that validates the components wire together
2. The downstream task depends on the integration task (not individual component tasks)

Integration tasks always have `## Produces: None` and `## Consumes: None`.
