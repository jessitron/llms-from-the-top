# Markov Chain Fixture

`workspace/markov.pl` is supposed to generate a string of text where each
word is likely to follow the word before it, based on word sequences seen in
`shakespeare-sonnets.txt`. It's broken: it picks one random word from the
input and prints that same word 50 times, instead of walking the chain of
likely successors.

## How to run

Point vort (or whatever agent) at `workspace/` — not this directory — and
ask it to fix `markov.pl`. Keeping vort scoped to `workspace/` matters: this
README is a spoiler, and vort_4d's `list_files`/`read_file` are cwd-scoped,
so vort never sees anything outside whatever directory it's pointed at.

To check by hand whether a fix actually works:

```
cd workspace && ./markov.pl < shakespeare-sonnets.txt
```

That should print 50 words that aren't all the same.

`eval_4.rb`, in this directory, automates exactly that: it copies
`workspace/` into a scratch dir, drives vort_4d.rb (or another vort script)
against the "fix my program" prompt, then runs the actual fixed
`markov.pl` and checks its output — rather than grading the chat transcript.

## Layout

- `workspace/` — what vort sees: `markov.pl`, `shakespeare-sonnets.txt`.
  Point vort here.
- `README.md` (this file) — for you, not vort. Stays out of vort's cwd.
- `eval_4.rb` — the automated eval; run it directly (`ruby eval_4.rb`).
