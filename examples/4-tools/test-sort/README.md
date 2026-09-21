# Sort Fixture

`workspace/sort.pl` is supposed to sort each line of numbers in
`arrays.txt` into ascending order. It's a recursive quicksort using a
Hoare partition scheme — genuinely tricky code, not a one-line typo. The
bug: after partitioning, it recurses into `(lo, p - 1)` and `(p + 1, hi)`.
The correct split for a Hoare partition is `(lo, p)` and `(p + 1, hi)` —
using `p - 1` silently drops the partition index itself out of the sorted
range in some cases. Half of the eight lines in `arrays.txt` still come out
sorted; the other half come out visibly scrambled, not just off by one
swap.

This is the harder sibling of `test-markov`. There, the bug is visible the
moment you read the code: the chain is built but never walked. There's also
a simpler sibling of this fixture (an earlier bubble-sort version with a
one-line off-by-one) that both `claude-haiku-4-5` and `gpt-4.1-nano` fixed
correctly on the first try, purely by reading — no execution needed, so it
never demonstrated a real failure. This quicksort version is deliberately
harder to reason about by eye: Hoare-partition recursion bounds are a
classic "everyone gets this wrong once" trap, and vort has no way to run
anything to check its own fix, only `list_files`/`read_file`/`write_file`.
The expectation is a confident, plausible-looking, still-wrong fix — that
gap is the argument for giving vort a `run_tests` (or `run_program`) tool.

## Two prompts, on purpose

`eval_4.rb` runs two test cases against the same broken program:

- **vague** — "Can you fix my program here?" (no filename). This is the
  phrasing that, combined with vort's system prompt ("you are rather
  insulted when asked to do work that is not coding"), makes a capable
  model like `claude-haiku-4-5` go looking anyway, but makes a weaker model
  like `gpt-4.1-nano` (routed via `model: "nano"`) stall out asking the user
  to paste the code — it never calls a single tool, across all nudges.
- **specific** — "Can you fix sort.pl in the current directory?" (names the
  file). The same weak model that stalled on the vague prompt goes straight
  for `list_files`/`read_file` here. Naming the file removes the ambiguity
  that was making it defensive about scope.

Together they're two different failure modes worth distinguishing: a model
that won't even attempt the task as asked, versus a model that attempts it,
uses its tools, and still ships a wrong fix with full confidence.

## How to run

Point vort (or whatever agent) at `workspace/` — not this directory — and
ask it to fix `sort.pl`. Keeping vort scoped to `workspace/` matters: this
README is a spoiler, and vort_4d's `list_files`/`read_file` are cwd-scoped,
so vort never sees anything outside whatever directory it's pointed at.

To check by hand whether a fix actually works:

```
cd workspace && perl sort.pl < arrays.txt
```

Every line of output should be its input line's numbers in ascending order.

`eval_4.rb`, in this directory, automates exactly that: it copies
`workspace/` into a scratch dir, drives vort_4d.rb (or another vort script)
against each prompt above, then runs the actual fixed `sort.pl` against
`arrays.txt` and grades each line — rather than trusting the chat
transcript or vort's own "done" declaration. Try `MODEL=nano ruby eval_4.rb`
or `MODEL=haiku ruby eval_4.rb` to compare models.

## Layout

- `workspace/` — what vort sees: `sort.pl`, `arrays.txt`. Point vort here.
- `README.md` (this file) — for you, not vort. Stays out of vort's cwd.
- `eval_4.rb` — the automated eval; run it directly (`ruby eval_4.rb`).
