# LLM API for use in the workshop

For this workshop, participants will write a baby agent. For that, they need a model. For that, there is this API that they can call.

## Architecture

The API composed here is OpenAI-compatible, since that's a standard.

It starts with /v1/completions, so we can see how a base model responds.

and then we can move to /v1/chat/completions.

## Models

"base" is https://huggingface.co/mistralai/Mistral-7B-v0.1

"chat" is an instruction-tuned version of that one: https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.1

"better" uses https://huggingface.co/mistralai/Mistral-Small-3.2-24B-Instruct-2506

## Deployment

Using Modal.com to run pretrained models on its infrastructure: `app.py`
deploys two [vLLM](https://docs.vllm.ai/) OpenAI-compatible servers, each its
own Modal GPU function (so each gets its own URL):

- `mistralai/Mistral-7B-v0.1` — a true base model (not instruction-tuned),
  served under the name `base`, so hitting `/v1/completions` shows raw
  completion behavior rather than chat-tuned behavior.
- `mistralai/Mistral-7B-Instruct-v0.1` — the chat-tuned sibling of the same
  base weights, served under the name `chat`, so `/v1/chat/completions`
  behaves like a normal chat model. Deliberately `-v0.1`, not `-v0.3`
  (which adds function-calling support we don't want here) — same tokenizer
  and architecture as the base model, so instruction-tuning is the only
  variable that changed.

Both run on an A10G rather than a T4, since 7B weights don't fit in a T4's
16GB alongside vLLM's KV cache.

### One-time setup

You need a Modal.com account and an authenticated `modal` CLI. Run
`setup-modal-account.sh` (ask Claude for it if it's not in this repo — it's a
one-time wizard, not meant to be re-run) and follow the prompts.

### Local dev

```
./run
```

Starts a temporary Modal endpoint (torn down on Ctrl-C) and prints its URL.
Good for iterating on `app.py`. Test it with, e.g.:

```
curl $URL/v1/completions -H 'content-type: application/json' -d '{
  "model": "base",
  "prompt": "The best way to learn a new programming language is",
  "max_tokens": 40
}'
```

`modal serve` prints a separate URL per function — the chat model's is the
one ending in `-serve-chat...modal.run`. Test it with:

```
curl $CHAT_URL/v1/chat/completions -H 'content-type: application/json' -d '{
  "model": "chat",
  "messages": [{"role": "user", "content": "What is the best way to learn a new programming language?"}],
  "max_tokens": 40
}'
```

### Persistent deploy

```
./deploy   # modal deploy — stays up (and billing GPU time) until stopped
./stop    # modal app stop — terminates it
```

`./deploy` also sends one warm-up request to each model right after deploying,
so the GPU spin-up and model load happen during `./deploy` instead of on the
first real caller's request.

Still to do:

- ~~custom domain (`llms-from-the-top.jessitron.com`) in front of the Modal URL~~ —
  see `../edge-proxy/` (a Cloudflare Worker, since Modal's own custom domains
  need a paid plan)

## Telemetry

Every request produces a three-span trace, spanning two Honeycomb services:

- a **root span** (`POST /v1/completions`) in `llms-from-the-top-edge-proxy`,
  from the Cloudflare Worker in `../edge-proxy/` — see that project's README
- a child **HTTP span** (`POST /v1/completions`) in `llms-from-the-top-api`,
  from `otel_middleware.py` here — client address, user-agent, the request
  body's `prompt`/`messages` (`gen_ai.prompt.*`), and the response's
  completion text and finish reason (`gen_ai.completion.*`)
- a grandchild **`llm_request` span**, from vLLM's own built-in tracing
  (`--otlp-traces-endpoint`) — queue time, time-to-first-token, token counts,
  and other `gen_ai.*` latency/usage attributes vLLM tracks internally

`otel_middleware.py` extracts the `traceparent` header edge-proxy sends, so
its span joins edge-proxy's trace instead of starting a new one (if there's
no such header — e.g. a request straight to the Modal URL, bypassing
edge-proxy — it falls back to being the root, as before). vLLM's own tracer
never records prompt/completion content (it's metrics-only), so
`otel_middleware.py` fills that gap itself: it's registered via vLLM's
`--middleware` flag (no vLLM source changes), and injects a fresh
`traceparent` header so its span and vLLM's `llm_request` span link into one
trace even though each runs its own independent `TracerProvider`.

Traces and logs go to an OTel collector (`workshop.jessitron.honeydemo.io`),
which forwards them on to Honeycomb — no API key or one-time secret setup
needed on the Modal side.

Caveats:

- `stream: true` requests aren't supported by the middleware (it buffers the
  full response body to read the completion text back out) — not needed for
  this workshop, so it's left unhandled rather than passed through.
- Request/response text is truncated to 4000 chars per field before being
  attached as a span attribute.
- vLLM's own tracing only covers request-level spans inside vLLM itself; there's
  nothing upstream (the agent side) or downstream to propagate trace context
  to yet, since vLLM is the whole app here.
