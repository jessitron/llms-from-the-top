# Project instructions

This is for a WORKSHOP. This is DEMO CODE. Do not worry about latency, resilience, or anything production-y.

I do care that it's pretty cheap to run. But it doesn't need to run long. A few hours during prep, a few hours during the workshop.

I care a lot about what data I can get out of it. This includes tracing. It also includes being able to save data in an ephemeral database, to make it easy to display live examples during the workshop.

Architecture:

locally, run code such as that in my-first-agent --> https://llms-from-the-top.jessitron.com --> some service that we implement, unnamed as yet --> llm-api on modal.app

## my-first-agent

This is where Jess writes the code she will hand-code live in the workshop, in different stages. Participants can download this repo and run that themselves, or write their own version.

## llm-api

We're using modal to run this, because it's a place we can run both a base model and a chat-trained model. The base model is tricky to find these days, and it's essential for the first step of illustrating that an LLM is a completion machine.

## Task tracking: use `yx`

This project tracks work with `yx`, a git-backed TODO CLI (`yx help` for full command list). Don't use TaskCreate/TaskUpdate for durable project work — those are session-scoped. Use `yx` instead so tasks persist across sessions and machines.

- `.yaks` is gitignored (required for `yx` to run at all — it'll error and tell you to fix this if it isn't).
- The yak history itself lives in git notes (`refs/notes/yaks`), not in `.yaks`, so it travels with the repo via `yx sync`.

Common commands:

- `yx list` — show the current tree (add `--ready` to see only actionable, unblocked yaks; `--format json` for scripting)
- `yx show <id>` — see details/context for one yak
- `yx add "name" [--under <parent-id>] [--context "..."]` — add a yak, optionally nested
- `yx start <id>` — mark as in-progress (wip)
- `yx done <id>` — mark complete
- `yx context <id>` — view a yak's freeform notes
- `yx context <id> <<< "All the context" ` — write the freeform notes
- `yx prune` — remove all done yaks (tidy up periodically)

When starting a new piece of work in this repo, check `yx list --ready` first before assuming what's next. When finishing a piece of work, mark the corresponding yak `done` rather than just leaving it.

## Create yaks liberally

Whenever you discover something that we should do, but right this instant is not the time to do it, add a yak!

Whenever the user mentions something additional to do, before you start investigating, add a yak!

When you want me to do something, make me a yak! Start the name with 👩🏽‍🦱 so that I can tell it's a job for a human.

## Finishing a worktree: use `scripts/merge-worktree.sh`

When work in a worktree is done, merge it into local main with this script rather than doing the merge/cleanup by hand. Run it from the main checkout (repo root), not from inside the worktree — use ExitWorktree first.

```
scripts/merge-worktree.sh [--keep-merge-commit] <branch-name> ["merge commit message"]
```

It fast-forwards main when possible (pass `--keep-merge-commit` to force a `--no-ff` merge commit instead), stashes any uncommitted changes in main first and restores them after, and removes the worktree and branch once merged. No push, no PR — this is a local-only merge, per the user's standing instruction to merge locally and never push/PR unless explicitly asked.

The script has a spot reserved for running the project's test suite after merging and before cleanup — there isn't one yet, so it currently just prints a note and skips. When this project gets tests (or a `./run` entry point), wire the invocation into that spot in the script.
