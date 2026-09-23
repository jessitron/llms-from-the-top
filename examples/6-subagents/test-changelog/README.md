# Changelog Fixture

Same fixture as `../../5-skills/test-changelog` (`workspace-5b`), copied here so
this stage is self-contained: `greeter.rb`, `CHANGELOG.md` already in the
project's format, and a short `AGENTS.md` that just says "update the
changelog" and "commit when instructed" — no format details, since those
live inside vort_6a's two subagent tools instead.

Here the challenge isn't getting the changelog format or commit style right
— vort_6a can't get those wrong, since it never sees the rules itself. The
challenge is whether vort_6a actually *delegates*: does it call
`write_changelog_entry` and `make_commit` rather than editing
`CHANGELOG.md` or running `git commit` directly with its own top-level
`write_file`/`run_command` tools?

## The task to give vort

Point vort_6a at `workspace/` and ask it to add a feature — e.g. "add a
`--shout` flag that uppercases the greeting, update the changelog, then
commit." Watch the console. The top-level loop should show
`write_changelog_entry(...)` and `make_commit(...)` calls, each followed by
its own one-line result — never the top-level agent calling `write_file`
on `CHANGELOG.md` itself, and never `run_command` with `git commit` at the
top level.

## How to check the result

```
ruby eval_6.rb
```

This drives `vort_6a.rb` against a throwaway copy of `workspace/` (with a
git repo initialized in it, so `make_commit`'s subagent has something real
to commit into), then checks: does `greeter.rb` actually behave the new
way, is the changelog entry present and correctly formatted, did vort_6a
delegate both steps instead of doing them itself, did each subagent stay
inside its restricted tools (the changelog subagent never calls
`run_command`, the commit subagent never calls `write_file`), and did a
real commit land with a message in this project's style. Results are also
posted to Honeycomb via `../../eval_telemetry.rb`, same as the other evals.

## Layout

- `workspace/` — what vort sees: `greeter.rb`, `CHANGELOG.md`, `AGENTS.md`.
  Point vort here.
- `README.md` (this file) — for you, not vort. Stays out of vort's cwd.
- `eval_6.rb` — the automated check; run it directly (`ruby eval_6.rb`).
