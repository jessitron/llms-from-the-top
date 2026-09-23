# 6 Subagents

A subagent is a tool call that, instead of doing one small thing, starts a
whole new conversation — its own system prompt, its own tools, its own
message history — does a task there, and hands back only the final result.

## Notice first

vort already has `run_command`, which is a shell. If the "why" for a
subagent is "so it can work in a different directory," that's not a reason
— vort can already `cd`. Don't reach for a subagent just for filesystem
scoping.

## Try this

`test-webapp/` still shows a real risk of subagents, though: point vort_6a
at it and ask it to rename a field across `frontend/` and `backend/` by
forking one subagent per directory. Each subagent only sees its own side,
so nothing forces them to agree on the new name — you may get `greeting` on
one side and `greeting_text` on the other. `ruby test-webapp/test_integration.rb`
checks whether they agreed. This is a caution about *isolation*, not a
reason to use subagents.

## Do this

The real reasons to reach for a subagent, shown in vort_6b:

1. **A clean, disposable context.** A skill (see `../5-skills`) loads
   instructions into the *calling* agent's own conversation, where they sit
   forever, competing with everything else in there, resent on every loop.
   A subagent's back-and-forth — reading a file, checking a format, trying
   again — happens in a conversation that gets thrown away once it returns
   its one-line result. None of that exploration cost accumulates in vort's
   own context.
2. **A procedure that can't be skipped or half-followed.** A skill is
   optional: vort has to notice it should load one, then correctly apply it
   itself. A subagent's entire system prompt *is* the procedure — there's
   nothing else in its context to get distracted by.
3. **Restricted tools per job.** `write_changelog_entry` delegates to a
   subagent that can only `read_file` and `write_file` — it has no way to
   run a shell command. `make_commit` delegates to a subagent that can only
   `read_file` and `run_command` — it has no way to edit a file. Each
   subagent can only do the kind of damage its job requires.

Example: vort_6b.rb

## Try this

Point vort_6b at `test-changelog/workspace/` (same fixture as `../5-skills`'
workspace-5b — `greeter.rb`, `CHANGELOG.md`, `AGENTS.md`) and ask it to add
a feature, e.g. "add a `--shout` flag that uppercases the greeting, don't
forget to update the changelog." Then ask it to commit. Watch the console:
the top-level loop only ever sees `write_changelog_entry(...)` and
`make_commit(...)` calls with their one-line results — never the
subagent's own reads, writes, or `git diff` calls.

## Notice that

vort_6b's top-level `AGENTS.md` doesn't say anything about changelog format
or commit style — it just says "update the changelog" and "commit when
instructed." The *how* lives entirely inside the two subagent tools, not in
anything the top-level model has to read, remember, or get right itself.
