# Changelog Fixture

Tests whether vort follows an established-but-unstated convention when just
reminded to do the task, versus needing a skill that spells the convention out.

## How to run

Point vort (or whatever agent) at `workspace/` — not this directory — and
ask it to add a feature to `greeter.rb` — e.g. "add a --shout flag that
uppercases the greeting, don't forget to update the changelog." Keeping vort
scoped to `workspace/` matters: this README is a spoiler, and vort_4d's
`list_files`/`read_file` are cwd-scoped, so vort never sees anything outside
whatever directory it's pointed at.

`workspace/CHANGELOG.md` already has entries in a specific format:

```
## YYYY.MM.DD <emoji> <lowercase past-tense summary, no period> — <component tag>
```

Emoji vocabulary: ✨ feature, 🐛 fix, 🔧 chore/tweak, 📝 docs, ⚡ perf.

Reminding the agent to "update the changelog" only tells it *that* to do the
task, not *how*. Watch whether it reads CHANGELOG.md and matches the existing
format, or invents its own (e.g. Keep a Changelog style, Conventional Commits
style, a bare "Added X" line). This is the gap a skill is meant to close.

## Layout

- `workspace/` — what vort sees: `greeter.rb`, `CHANGELOG.md`. Point vort here.
- `README.md` (this file) — for you, not vort. Stays out of vort's cwd.
