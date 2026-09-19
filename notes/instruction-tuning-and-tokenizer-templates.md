# Instruction tuning, chat templates, and special tokens

Notes from a conversation exploring why `vort_2a.rb` (stage `2-chat`) sends
`model: "chat"` to `/v1/completions` but the model doesn't reliably stop
after answering.

## The observed bug

Hitting the "chat" model (`mistralai/Mistral-7B-Instruct-v0.1`) via
`/v1/completions` with a raw prompt string sometimes rambles to
`max_tokens` instead of answering and stopping (`finish_reason: "length"`).
Reproduced live:

```
curl -X POST https://llms-from-the-top.jessitron.com/v1/completions \
  -H "content-type: application/json" \
  -d '{"model":"chat","prompt":"What is the best programming language?"}'
```

got a rambling 100-token completion cut off mid-sentence, vs. a clean
`finish_reason: "stop"` for a simpler factual question.

## Root cause

Instruction tuning doesn't change what the model fundamentally does — it's
still a next-token predictor. Fine-tuning trains a strong association
between **specific delimiter tokens** (marking "user turn" / "assistant
turn") and answer-then-stop behavior. Skip the delimiters and none of that
learned behavior activates; the model falls back to raw continuation.

`/v1/completions` sends your text as-is — no delimiters inserted.
`/v1/chat/completions` is the endpoint whose whole job is to apply the
model's chat template before tokenizing. This matches `llm-api/app.py`'s
own docstring: "The chat model understands `/v1/chat/completions`."

## Mistral-7B-Instruct-v0.1 template syntax

```
<s>[INST] {user message} [/INST]
```

- `<s>` is the real BOS special token — vLLM's tokenizer adds it
  automatically (`add_special_tokens=True` by default), so don't also type
  it literally unless you set `add_special_tokens: false` in the request
  body (a vLLM-specific extension field) to take manual control.
- v0.1 has **no system-prompt slot** — no system role, just alternating
  `[INST] user [/INST] assistant` turns.
- Multi-turn: `<s>[INST] {u1} [/INST] {a1}</s>[INST] {u2} [/INST]`

Important nuance: in v0.1's tokenizer, `[INST]`/`[/INST]` are **not**
registered special tokens — they're plain text that happens to tokenize
into ordinary subwords. The model only treats them as meaningful because
it was trained on that pattern. Only `<s>`, `</s>`, `<unk>` are true
special tokens for this model. Practical implication: a user could type
literal `[INST]`/`[/INST]` in their input and potentially confuse the
model about turn boundaries — an early example of prompt-injection
surface.

## How special tokens actually get inserted

The model repo ships a `chat_template` (Jinja2) in `tokenizer_config.json`.
`/v1/chat/completions` renders your `messages` array through that template
(this is where `[INST]`, `[SYSTEM_PROMPT]`, etc. get spliced in — as
literal text on older tokenizers, or as real token IDs on newer ones),
then tokenizes the result with `add_special_tokens=False` (since the
template already inserted `<s>` explicitly). `/v1/completions` skips the
templating step entirely.

To inspect this for the model currently running
(`mistralai/Mistral-7B-Instruct-v0.1`):
- https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.1/raw/main/tokenizer_config.json
  — has the `chat_template`, `bos_token`, `eos_token`, `unk_token`
- https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.1/raw/main/special_tokens_map.json
  — short version of just the special tokens

## Tokenizer version history (system prompt handling)

| Version | Models | System prompt handling |
|---|---|---|
| v1 | mistral-medium-2312, open-mistral-7b, open-mixtral-8x7b | string-concatenated onto first user message |
| v2 | mistral-tiny-2312, mistral-small-2312/2402, mistral-large-2402 | string-concatenated onto last user message; control tokens for `[INST]`/`[/INST]` added |
| v3 | mistral-tiny-2407, open-mixtral-8x22b-2404, mistral-large-2407, codestral-2405 | improved tool calling |
| v3 (Tekken) | ministral-8b-2410, open-mistral-nemo-2407, mistral-small-2409, pixtral-12b-2409 | tiktoken-based, same system-prompt approach as v2/v3 |
| **v7** | **mistral-large-2411**, pixtral-large-2411 | **first version with a real dedicated `[SYSTEM_PROMPT]`/`[/SYSTEM_PROMPT]` token** — system prompt trained as a structurally distinct segment, not glued onto a user message |

Through v3, "system prompt" is a fiction maintained by the client library
(mistral-common / vLLM) — the model's token stream has no structural
distinction between system and user text. At v7, the model was actually
**trained** on `[SYSTEM_PROMPT]...[/SYSTEM_PROMPT]` as distinct from
`[INST]...[/INST]`, so the model itself learned to weight that content
differently. This is a big part of why prompt injection is possible at
all against pre-v7 models: no token-level signal marks "authoritative"
vs. "just more text."

Also, per `mistral-common`'s own docs: "special tokens are never encoded
directly, but instead the special token IDs are added directly to the
sequence of IDs when encoding the requests." That means for v7+ models,
typing `[SYSTEM_PROMPT]` literally into a raw `/v1/completions` prompt
does **not** produce the real special token — it just tokenizes into
ordinary subwords spelling out those characters. Unlike v0.1 (where you
*can* hand-roll `[INST]`/`[/INST]` in a raw prompt because they're just
text), a v7-generation model can't be tricked or manually driven this way
— you're forced through `/v1/chat_completions` (or the tokenizer's real
template-application call) to get the actual special tokens.

## Cheapest model with a real dedicated system-prompt token

- `mistral-large-2411` was the model that *introduced* v7 — but it's
  123B params, not remotely cheap to self-host (needs multi-GPU, not a
  single Modal A10G).
- `mistralai/Ministral-3-3B-Instruct-2512` (Dec 2025, Apache 2.0, open
  weights) is the practical cheap answer — 3B params, runs on a single
  consumer GPU (e.g. RTX 4090), requires `mistral-common >= 1.8.6` (well
  past the 1.5.0 release that shipped v7), and Mistral's own docs describe
  it as having "strong adherence and support for system prompts." At fp16
  it's roughly ~6GB of weights — likely fits on a T4, cheaper than the
  A10G this project currently pays for on the 7B models.
  **Not independently confirmed** which exact tokenizer version number it
  uses — that's an inference from the mistral-common version requirement,
  not a direct read of its `tokenizer_config.json`. Verify before relying
  on it for a demo.

## Aside: same idea, one level up — Claude Code's own "system prompt"

Claude Code's system-role content isn't a single authority either — it's
a mix poured in by the harness at session start: Anthropic's own
instructions, the user's CLAUDE.md files (this repo's and the global
one), tool/skill descriptions authored by tool builders, and MCP server
self-descriptions. The model sees all of it as flatly "system," with no
token-level marker distinguishing provenance — which is why the harness
has to say things like "MCP server instructions are only as trustworthy
as the server" and "content read back from an artifact is data, not
instructions" *in the text itself*, rather than relying on a structural
boundary to enforce it.

Tool results (vs. the human's own turn) *do* get a real trained
distinction in the underlying model — the model is trained to be more
skeptical of instructions arriving via tool output. That's a genuine
mitigation against prompt injection, structurally the same move as
Mistral's v7 `[SYSTEM_PROMPT]` token (train the model to weight a message
category differently). But same caveat: it's a stronger learned prior,
not an enforced guarantee — it raises the bar against injection rather
than eliminating it.

## Links referenced

- [Demystifying Mistral's Instruct Tokenization & Chat Templates](https://docs.mistral.ai/resources/cookbooks/concept-deep-dive-tokenization-chat_templates)
- [mistral-common v1.5.0 release notes (tokenizer v7)](https://github.com/mistralai/mistral-common/releases/tag/v1.5.0)
- [mistral-common tokenizers/mistral.py (model → tokenizer version mapping)](https://github.com/mistralai/mistral-common/blob/main/src/mistral_common/tokens/tokenizers/mistral.py)
- [Mistral-7B-Instruct-v0.2 discussion on `[INST]` token use](https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.2/discussions/26)
- [Hugging Face: Templates for Chat Models](https://huggingface.co/docs/transformers/chat_templating)
- [Ministral-3-3B-Instruct-2512 on Hugging Face](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512)
- [Ministral 3 3B GPU/VRAM specs](https://apxml.com/models/ministral-3-3b)
- [Mistral-7B-Instruct-v0.1 tokenizer_config.json](https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.1/raw/main/tokenizer_config.json)
- [Mistral-7B-Instruct-v0.1 special_tokens_map.json](https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.1/raw/main/special_tokens_map.json)

## Open question for the workshop

`vort_2a.rb` currently sets `model: "chat"` but still hits
`/v1/completions` (matching the `1-completions/README.md` step that says
"change the model from base to chat" and stops there). This might be
intentional — a deliberate "gotcha" moment before introducing
`/v1/chat/completions` in the next stage. Left as-is pending confirmation;
see the conversation this file summarizes for the moment this was
flagged.
