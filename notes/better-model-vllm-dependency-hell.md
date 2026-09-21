# The "better" model's vLLM dependency hell (2026-09-20)

`llm-api/app-better.py` serves `mistralai/Mistral-Small-3.2-24B-Instruct-2506`
on an A100-80GB. It was pinned to `vllm==0.6.6.post1` (same as `app.py`'s
base/chat pair) and every `./deploy-better` attempt failed — after burning
GPU time downloading the 24B weights first. Fixed by working through three
layered incompatibilities, each one only visible once the previous one was
patched.

## Layer 1: vLLM too old for the model's architecture

`vllm==0.6.6.post1` predates support for `Mistral3ForConditionalGeneration`,
the architecture this model uses (it's the HF-format, vision-capable Mistral
Small 3.x line). Every deploy: download 48GB of weights onto the A100, try to
start the engine, crash with:

```
ValueError: Model architectures ['Mistral3ForConditionalGeneration'] are not
supported for now.
```

That download-then-crash cycle is what was costing money for nothing.

**Fix direction:** bump vLLM. `Mistral3ForConditionalGeneration` support
landed in vLLM 0.8.3. Avoid 0.8.4 — it had a known regression for Mistral
Small 3.1 image inference. Landed on `vllm==0.8.5`.

## Layer 2: unpinned transformers, resolved too new

Bumping to `vllm==0.8.5` needed cascading version bumps just to get the
pip install to resolve (`huggingface_hub>=0.30.0`, `opentelemetry-sdk`
`<1.27.0` — vLLM 0.8.5 pins that ceiling itself). Once the image built, a
new crash appeared, this time at import time rather than at engine-start:

```
ImportError: cannot import name 'PixtralRotaryEmbedding' from
'transformers.models.pixtral.modeling_pixtral'
```

We hadn't pinned `transformers`, so pip picked the newest release
satisfying vLLM's own `>=4.51.1` floor — which turned out to be a version
that renamed `PixtralRotaryEmbedding` to `PixtralVisionRotaryEmbedding`.
vLLM 0.8.5's own `pixtral.py` still imports the old name, so it broke on
import before ever touching the GPU.

**Fix:** pin `transformers==4.53.0` — new enough for vLLM 0.8.5's floor and
for `mistral3` config support, old enough to predate the rename.

## Layer 3: this HF repo is actually mistral-native format

With the architecture and import problems solved, the engine got as far as
initializing before a new failure, this time from the *tokenizer*:

```
KeyError: <class 'transformers.models.mistral3.configuration_mistral3.Mistral3Config'>
```

`transformers` doesn't have `Mistral3Config` in its `AutoTokenizer`
mapping. vLLM's own log output hints at the fix: "strongly recommended to
run mistral models with `--tokenizer-mode mistral`" — that swaps in
Mistral's own tokenizer library instead of going through HF's
`AutoTokenizer`.

Adding just `--tokenizer-mode mistral` traded that error for a different
one, after a full weight reload:

```
OSError: mistralai/Mistral-Small-3.2-24B-Instruct-2506 does not appear to
have a file named preprocessor_config.json.
```

Checked the HF repo's file listing directly — it really doesn't have
`preprocessor_config.json` or `tokenizer_config.json`. It has
`tekken.json`, `params.json`, and `consolidated.safetensors` instead: this
repo is laid out in Mistral's own native format, not full HF-transformers
format, even though it also happens to contain HF-style sharded
`model-*.safetensors` files. `--tokenizer-mode mistral` alone still routes
config/weight loading through the HF path, which goes looking for a
processor config that isn't there.

**Fix:** vLLM's own Mistral-Small serving guide
(`docs.vllm.ai/en/v0.8.5/getting_started/examples/mistral-small.html`)
confirms all three mistral-format flags are needed together for this repo
layout:

```
--tokenizer-mode mistral --config-format mistral --load-format mistral
```

`--load-format mistral` makes vLLM load `consolidated.safetensors`
(a different file than the sharded ones — yet another full weight
download) instead of the HF-style shards.

Since this demo is text-only, also added `--limit-mm-per-prompt '{"image":0}'`
to skip the vision path entirely (the doc's own example uses `{"image":4}`
since the model is vision-capable by default).

## Gotcha: quoting `--limit-mm-per-prompt`'s JSON value

`serve_better()` builds `cmd` as a list, joins it with spaces, and runs it
via `subprocess.Popen(..., shell=True)`. A plain Python string
`'{"image":0}'` has no shell-level quoting once it's spliced into that
joined command — bash would strip the double quotes before vLLM ever saw
them, turning valid JSON into garbage. Needed literal single quotes
*inside* the string that survive the join: `"'{\"image\":0}'"`.

## End state

```python
"vllm==0.8.5",
"transformers==4.53.0",
"huggingface_hub[hf_transfer]>=0.30.0",
"opentelemetry-sdk==1.26.0",
"opentelemetry-exporter-otlp-proto-http==1.26.0",
```

```python
"--tokenizer-mode", "mistral",
"--config-format", "mistral",
"--load-format", "mistral",
"--limit-mm-per-prompt", "'{\"image\":0}'",
```

Verified end-to-end: deployed, sent a warm-up `/v1/chat/completions`
request, got `HTTP 200` back with a real completion, then stopped the app.

## Lesson for next time

When bumping a pinned dependency to fix one error, check what *else* was
implicitly pinned by the old version before it's proven compatible with the
new one (transitive deps like `transformers`, `huggingface_hub`,
`opentelemetry-sdk` all needed follow-up pins here). And check a model's HF
repo file listing before assuming "HF format" — a repo can look like
HF-transformers format (has `config.json`, sharded `.safetensors`) while
actually requiring Mistral's native loading path.
