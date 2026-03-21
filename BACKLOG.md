# Swarm Backlog

## P2: Screenshot cleanup — remove verification screenshots from git history

**Problem:** Workers write screenshots to `screenshots/` during visual parity verification. These accumulate as loose git objects and have ballooned the repo to 12GB+ (393 PNGs, 11GB loose objects), causing `git clone` to time out in fresh containers.

**Short-term:** `git gc` packs loose objects — clone becomes fast again without data loss.

**Long-term fix:**
1. Add `screenshots/` and `Tests/UI/baselines/` to `.gitignore` in project template
2. After a run completes, run `git filter-repo --path screenshots/ --invert-paths` (BFG alternative) to strip screenshot history
3. Force-push the cleaned repo and have workers re-clone

**Notes:** Do NOT do this mid-run (active workers would conflict). Safe to do after final reviewer passes. Only affects the project repo inside the run output dir, not the swarm framework repo.

