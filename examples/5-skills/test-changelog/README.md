# Changelog Fixture

Here, the challenge is not making the code change, but in getting the changelog entry right.

For a regular feature, it can copy the existing changelog entries. But for a breaking change, there are special rules that it wouldn't know.

In workspace-5a, those rules are in AGENTS.md. Vort_5a will read that at the beginning.

In workspace-5b, there are skills. Vort_5b will offer those skills.

Which of them will work better? (hopefully they both work)
Which of them will be more efficient?

## How to run

Point vort (or whatever agent) at `workspace_5a/` — not this directory — and
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

Reminding the agent to "update the changelog" only tells it _that_ to do the
task, not _how_. Watch whether it reads CHANGELOG.md and matches the existing
format, or invents its own (e.g. Keep a Changelog style, Conventional Commits
style, a bare "Added X" line). This is the gap a skill is meant to close.

## Layout

- `workspace/` — what vort sees: `greeter.rb`, `CHANGELOG.md`. Point vort here.
- `README.md` (this file) — for you, not vort. Stays out of vort's cwd.

## Planned twist: breaking change

The three seed entries are all ✨/🐛 on one component, so haiku can pattern-match
the format without much effort. To make the gap more convincing, ask for a
**breaking change** instead — e.g. rename `greeter.rb`'s positional name arg
into a required `--name` flag.

Breaking changes are a case where vort (and most people) _do_ have strong
priors from other repos — semver, Conventional Commits' `BREAKING CHANGE:`
footer, GitHub release notes — none of which match this project's actual
convention, and none of which are demonstrated in the seed entries. Expect a
confident, plausible, wrong answer rather than "I don't know the convention
for this."

The real convention (for the eventual skill to state, not for vort to infer):
breaking changes use 💥 and are followed by an indented `migrate:` line
explaining the upgrade, e.g.:

```
## 2024.02.01 💥 renamed --name positional arg to --name flag — greeter
   migrate: replace `greeter Alice` with `greeter --name Alice`
```
