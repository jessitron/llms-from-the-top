# Project instructions

## Task tracking: use `yx`

This project tracks work with `yx`, a git-backed TODO CLI (`yx help` for full command list). Don't use TaskCreate/TaskUpdate for durable project work — those are session-scoped. Use `yx` instead so tasks persist across sessions and machines.

- `.yaks` is gitignored (required for `yx` to run at all — it'll error and tell you to fix this if it isn't).
- The yak history itself lives in git notes (`refs/notes/yaks`), not in `.yaks`, so it travels with the repo via `yx sync`.

Common commands:
- `yx list` — show the current tree (add `--ready` to see only actionable, unblocked yaks; `--format json` for scripting)
- `yx add "name" [--under <parent-id>] [--context "..."]` — add a yak, optionally nested
- `yx start <id>` — mark as in-progress (wip)
- `yx done <id>` — mark complete
- `yx show <id>` — see details/context for one yak
- `yx context <id>` — view or edit a yak's freeform notes
- `yx prune` — remove all done yaks (tidy up periodically)

When starting a new piece of work in this repo, check `yx list --ready` first before assuming what's next. When finishing a piece of work, mark the corresponding yak `done` rather than just leaving it.

## Finishing a worktree: use `scripts/merge-worktree.sh`

When work in a worktree is done, merge it into local main with this script rather than doing the merge/cleanup by hand. Run it from the main checkout (repo root), not from inside the worktree — use ExitWorktree first.

```
scripts/merge-worktree.sh [--keep-merge-commit] <branch-name> ["merge commit message"]
```

It fast-forwards main when possible (pass `--keep-merge-commit` to force a `--no-ff` merge commit instead), stashes any uncommitted changes in main first and restores them after, and removes the worktree and branch once merged. No push, no PR — this is a local-only merge, per the user's standing instruction to merge locally and never push/PR unless explicitly asked.

The script has a spot reserved for running the project's test suite after merging and before cleanup — there isn't one yet, so it currently just prints a note and skips. When this project gets tests (or a `./run` entry point), wire the invocation into that spot in the script.
