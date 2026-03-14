# Swarm Prompt Improvements — Design Spec
*2026-03-14*

## Goal

Improve orchestrator and worker prompts so swarm reliably handles large projects (15+ components, full-stack apps) without workers building components that fail to integrate.

## Problem Statement

The current system works well for small-to-medium projects but breaks down at scale due to three issues:

1. **No interface contracts** — tasks specify what to build but not the exact APIs, function signatures, and file paths they produce or consume. Workers build components that don't wire together.
2. **Workers read too much context** — the "read SPEC.md first" instruction causes workers to consume the entire project spec on every invocation, wasting context window as the project grows.
3. **Integration failures surface late** — a single final verification task tries to fix everything at once instead of catching mismatches at natural seams.

## Design

### SPEC.md: New `## Interfaces` Section

The orchestrator adds a mandatory `## Interfaces` section to SPEC.md. This is the contract hub — every module's public API defined as named, standalone subsections:

```markdown
## Interfaces

### DatabaseSession
- File: `src/db.py`
- `get_session() -> Generator[Session, None, None]`
- `init_db() -> None`

### UserAPI
- File: `src/models/user.py`
- `class User: id: int, email: str, hashed_password: str, created_at: datetime`
- `POST /api/users` — body: `{email: str, password: str}` → `{id, email, created_at}`
- `GET /api/users/{id}` → `User`
```

Each interface subsection must be self-contained and readable in isolation. The orchestrator owns this section and keeps it accurate. Workers never modify it.

### Task File Format

Task files gain two new mandatory sections:

```markdown
## Produces
The named interface this task implements, as defined in SPEC.md § Interfaces:
- Implements: `UserAPI`

## Consumes
Named interfaces this task depends on, from SPEC.md § Interfaces:
- `DatabaseSession`
- `AuthTokenAPI`
```

`## Produces` names the interface contract this task fulfills.
`## Consumes` lists the specific interface names workers must read from SPEC.md § Interfaces before starting.

### Task Count and Granularity

No lower or upper bound on task count — the orchestrator decides based on project complexity. The rule: **a task is the right size when a worker can complete it by reading only its task file and its listed interface definitions.** If completing a task requires understanding the whole codebase, split it.

### Integration Tasks

The orchestrator inserts integration tasks at natural seams — whenever a group of completed tasks forms a testable subsystem. The signal: *can we run something end-to-end at this point?*

Integration tasks are regular tasks with explicit dependencies on everything they validate. The existing git lock mechanism enforces this: an integration task won't be claimable until all its dependencies are in `tasks/done/`.

Example placement: after all database/model tasks complete and before API tasks start, insert `050-integration-data-layer.md` that wires and smoke-tests the foundation.

### Worker Protocol Changes

**Before (current):**
1. `git pull`
2. Read `SPEC.md` (entire document)
3. Check pending tasks
4. Claim and execute

**After:**
1. `git pull`
2. Read task file
3. Read only the interface definitions listed in `## Consumes` from SPEC.md § Interfaces
4. Confirm dependencies are in `tasks/done/`
5. Claim and execute

Workers read the specific interfaces they need — not the full spec. As the project grows, a worker building auth reads `UserAPI` and `DatabaseSession`, not the 20 other interfaces defined for the rest of the system.

## Files to Change

- `prompts/orchestrator.md` — add Interfaces section requirement, update task file format, add integration task guidance, remove task count bounds
- `prompts/worker.md` — replace "read SPEC.md" with targeted interface reading, update protocol steps

## Success Criteria

- [ ] Orchestrator reliably produces a SPEC.md with a well-structured `## Interfaces` section
- [ ] All task files include `## Produces` and `## Consumes` sections with named interface references
- [ ] Integration tasks appear at natural seams in the task graph, not just at the end
- [ ] Workers read only their required interface definitions, not the full SPEC.md
- [ ] A full-stack app (auth + DB + API + frontend, 15+ components) completes with components that integrate correctly on first attempt
