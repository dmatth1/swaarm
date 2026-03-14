# Swarm Prompt Improvements — Design Spec
*2026-03-14*

## Goal

Improve orchestrator and worker prompts so swarm reliably handles large projects (15+ components, full-stack apps) without workers building components that fail to integrate.

## Problem Statement

The current system works well for small-to-medium projects but breaks down at scale due to three issues:

1. **No interface contracts** — tasks specify what to build but not the exact APIs, function signatures, and file paths they produce or consume. Workers build components that don't wire together.
2. **Workers read too much context** — the "read SPEC.md first" instruction causes workers to consume the entire project spec on every invocation, wasting context window as the project grows.
3. **Integration failures surface late** — a single final verification task tries to fix everything at once instead of catching mismatches at natural seams.

## Out of Scope

Interface correction when a worker deviates from a specified contract is handled by multi-round orchestration (future work). This spec assumes workers implement to contract.

## Design

### SPEC.md: New `## Interfaces` Section

The orchestrator adds a mandatory `## Interfaces` section to SPEC.md. This is the contract hub — every module's public API defined as named, standalone subsections.

SPEC.md structure: all non-interface content (Goal, Architecture, Technology Stack, File Structure, Success Criteria, Key Decisions) comes first. The `## Interfaces` section is always **last**, enabling workers to stop reading before it:

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
Implements: `UserAPI`

## Consumes
DatabaseSession
AuthTokenAPI
```

When a task produces or consumes nothing, write the bare word `None` on the line after the header — no backticks, no bullet:

```markdown
## Produces
None

## Consumes
None
```

`## Produces` names the interface this task fulfills, or `None`.
`## Consumes` lists specific interface names (one per line), or `None`.

Workers enumerate all entries in `## Consumes` using:
```bash
awk '/^## Consumes/{found=1; next} found && /^## /{exit} found && NF{print}' taskfile.md
# prints each non-blank line between "## Consumes" and the next "##" heading
# outputs nothing when the section body is "None" — treat empty output as None
```

**Integration tasks always write `## Produces` and `## Consumes` as `None`** — they validate components against real code, not interface contracts, and they do not define new contracts.

The existing "tasks should be self-contained — a worker needs only SPEC.md and the task file" rule in `orchestrator.md` is **replaced** by: "a task is the right size when a worker can complete it by reading SPEC.md (non-Interfaces sections) plus the task file plus only its listed interface definitions."

### Task Count and Granularity

No bounds on task count — the orchestrator decides based on project complexity. The sizing rule above is the only constraint.

### Integration Tasks

The orchestrator inserts an integration task **when designing a downstream task whose `## Consumes` would list 3 or more entries**. Instead of that downstream task consuming 3+ interfaces directly, insert an integration task that validates those components first, then have the downstream task depend on the integration task with a smaller `## Consumes`. Only non-integration tasks count toward the threshold.

Integration tasks:
- `## Produces: None`
- `## Consumes: None` (they read actual code, not interface contracts)
- `## Dependencies`: all component tasks they validate
- Body: smoke tests that verify the components wire together and produce expected outputs against their SPEC.md interface definitions

Downstream tasks must list the integration task as their dependency — not the individual component tasks.

Example placement for a full-stack app:
- After `001`–`004` (DB models, migrations, connection pool) → `005-integration-data-layer.md` (smoke tests DB round-trip)
- After `006`–`012` (API routes, auth, middleware) → `013-integration-api-layer.md` (smoke tests API endpoints)
- Final: `NNN-integration-full-stack.md` after all layers are integrated

### Worker Protocol Changes

**Before (current):**
1. `git pull`
2. Read `SPEC.md` (entire document)
3. Check pending tasks, read task files to check dependencies
4. Claim and execute

**After:**
1. `git pull`
2. Read SPEC.md architecture context — everything up to but not including `## Interfaces` — using:
   ```bash
   awk '/^## Interfaces/{exit} {print}' SPEC.md
   ```
3. Scan pending tasks; read each task file briefly to check `## Dependencies`. Skip tasks whose dependencies aren't in `tasks/done/`.
4. Pick lowest-numbered available candidate.
5. **Claim** (push to active; if push fails, return to step 3).
6. After successful claim: read `## Consumes` from the claimed task file.
   - If `None`: skip this step entirely.
   - Otherwise, for each named interface listed, extract that subsection from SPEC.md using:
     ```bash
     awk '/^### InterfaceName$/{found=1; next} found && /^### /{exit} found{print}' SPEC.md
     ```
     (Replace `InterfaceName` with the actual interface name. Run once per listed interface.)
7. Execute.

## Files to Change

- `prompts/orchestrator.md`:
  - Add `## Interfaces` section requirement (always last in SPEC.md)
  - Update task file format with `## Produces`/`## Consumes` including `None` conventions
  - Specify integration tasks always have `## Produces: None` and `## Consumes: None`
  - Replace "Tasks should be self-contained" rule with updated sizing rule
  - Add integration task insertion rule (3+ non-integration tasks sharing a downstream consumer)
  - Remove task count bounds
- `prompts/worker.md`:
  - Replace "Read SPEC.md" with the `awk` command for partial read
  - Add post-claim targeted interface extraction with `awk` command
  - Add `None` branch: skip interface read if `## Consumes` is `None`
  - Update protocol steps

## Success Criteria

- [ ] Orchestrator produces a SPEC.md with `## Interfaces` as the last section on every run
- [ ] All task files include `## Produces` and `## Consumes` (or explicit `None`)
- [ ] Integration tasks always have `## Produces: None` and `## Consumes: None`
- [ ] Integration tasks appear after every group of 3+ non-integration tasks sharing a downstream consumer
- [ ] Workers use the `awk` command to read SPEC.md architecture sections without loading the Interfaces section
- [ ] Workers skip interface extraction when `## Consumes` is `None`
- [ ] Workers use targeted `awk` extraction to read only their listed interface definitions post-claim
- [ ] A full-stack app (auth + DB + API + frontend, 15+ components) completes with components that integrate correctly on first attempt
