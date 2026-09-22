# Frontend/Backend Fork Fixture

`workspace/` is a tiny webapp: `backend/server.rb` serves `GET /api/greeting`
as `{"message": "hello from backend"}`, and `frontend/index.html` fetches
that endpoint and displays the `message` field. The two sides agree on the
field name — that agreement is the thing under test.

## The task to give vort

Point vort (or whatever agent) at `workspace/` and ask it to rename the
`message` field to `greeting` everywhere. This is a good task for
vort_6a specifically because it invites forking one subagent into
`backend/` and another into `frontend/`: each subagent only sees its own
directory, so nothing forces them to agree on the new name except getting
it right independently. If one subagent renames to `greeting` and the
other guesses `greeting_text`, the app breaks even though both halves
"succeeded" at their own task.

Keeping vort scoped to `workspace/` matters: this README is a spoiler.

## How to check the result

```
ruby test_integration.rb
```

This starts `workspace/backend/server.rb`, hits `/api/greeting`, and checks
that `workspace/frontend/index.html` references whatever field name the
backend actually returned. It doesn't hardcode "message" or "greeting" —
it just checks that both sides ended up using the *same* name, so it works
whether vort did the rename or not, and would also catch a
frontend/backend field mismatch introduced any other way.

## Layout

- `workspace/` — what vort sees: `frontend/index.html`, `backend/server.rb`.
  Point vort here.
- `README.md` (this file) — for you, not vort. Stays out of vort's cwd.
- `test_integration.rb` — the integration check; run it directly
  (`ruby test_integration.rb`).
