# Context length, max_tokens, and GPU headroom

## /v1/chat/completions default max_tokens

We serve via vLLM's OpenAI-compatible server (`llm-api/app.py`, vLLM 0.6.6.post1).
If a request omits `max_tokens`, vLLM does NOT use a small hardcoded default —
it fills whatever context room is left after the prompt (confirmed in vLLM's
`serving_chat.py` for this version):

```python
default_max_tokens = self.max_model_len - len(engine_prompt["prompt_token_ids"])
```

So the effective cap on a request is `--max-model-len` minus prompt length,
not something the client needs to set explicitly (unless we want a safety net
against a runaway generation before the model hits its own stop token).

## Current setting: --max-model-len 2048

`llm-api/app.py` (`_serve_vllm`) currently sets `--max-model-len 2048`. That's
total context — prompt + output combined. Comment in the code explains why:
Mistral-7B's default max_model_len (32768) needs more KV cache than an A10G
(24GB VRAM) has room for once the ~14GB of fp16 weights are loaded.

KV cache cost for Mistral-7B (GQA, 8 kv heads, head_dim 128, 32 layers, fp16):

```
2 (K&V) × 32 layers × 8 kv_heads × 128 head_dim × 2 bytes ≈ 128 KB / token / sequence
```

At `--max-model-len 2048` with `max_inputs=32` concurrent requests:
`2048 × 128KB × 32 ≈ 8GB` KV cache — most of what's left on the A10G after weights.

## Problem: a coding demo needs ~10K output tokens

2048 total context isn't close to enough for a ~10K-token generation. To fit
that we'd need `--max-model-len` around 12-16K (prompt + output).

At 32 concurrent sequences, that blows way past the A10G:
`12288 × 128KB × 32 ≈ 49GB` of KV cache alone — not going to fit in 24GB.

### Options for the coding-demo function specifically

1. **Drop concurrency hard** (e.g. `max_inputs=2-4`) and raise
   `--max-model-len` to ~12-16K. Fine if it's just Jess running one request
   at a time during that part of the workshop.
2. **Bump the GPU tier** for that function (e.g. `gpu="A100"` on Modal,
   40/80GB) and keep concurrency higher — costs more per hour, but this only
   needs to run for a few hours during prep/workshop.

Decision not made yet — revisit when we build the coding-demo step.
