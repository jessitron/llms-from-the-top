# LLM API for use in the workshop

For this workshop, participants will write a baby agent. For that, they need a model. For that, there is this API that they can call.

## Architecture

The API composed here is OpenAI-compatible, since that's a standard.

It starts with /v1/completions, so we can see how a base model responds.

and then we can move to /v1/chat/completions later, maybe. Maybe we'll keep using /completions and put the template on the agent side, for clarity of what's happening!

## Deployment

Using Modal.com to run a pretrained model on its infrastructure: `app.py` deploys
[vLLM](https://docs.vllm.ai/)'s OpenAI-compatible server on a Modal GPU function.

The base model is `Qwen/Qwen2.5-0.5B` — a true base model (not instruction-tuned),
served under the name `base`, so hitting `/v1/completions` shows raw completion
behavior rather than chat-tuned behavior.

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

### Persistent deploy

```
./start   # modal deploy — stays up (and billing GPU time) until stopped
./stop    # modal app stop — terminates it
```

`./start` also sends one warm-up request right after deploying, so the GPU
spin-up and model load happen during `./start` instead of on the first real
caller's request.

Still to do:
- custom domain (`llms-from-the-top.jessitron.com`) in front of the Modal URL
- `x-api-key` auth and `use-this-model-please` header routing (base vs. trained model)
- a second, chat/instruction-tuned model for the "trained" path

## Telemetry

Every request produces a two-span trace in Honeycomb (service
`llms-from-the-top-api`):

- a root **HTTP span** (`POST /v1/completions`), from `otel_middleware.py` —
  client address, user-agent, the request body's `prompt`/`messages`
  (`gen_ai.prompt.*`), and the response's completion text and finish reason
  (`gen_ai.completion.*`)
- a child **`llm_request` span**, from vLLM's own built-in tracing
  (`--otlp-traces-endpoint`) — queue time, time-to-first-token, token counts,
  and other `gen_ai.*` latency/usage attributes vLLM tracks internally

vLLM's own tracer never records prompt/completion content (it's metrics-only),
so `otel_middleware.py` fills that gap itself: it's registered via vLLM's
`--middleware` flag (no vLLM source changes), and injects a `traceparent`
header so its span and vLLM's `llm_request` span link into one trace even
though each runs its own independent `TracerProvider`.

One-time setup, before your first deploy:

```
modal secret create honeycomb HONEYCOMB_API_KEY=<your Honeycomb API key>
```

That's it — `./run`, `./start`, etc. all pick it up automatically.

Caveats:
- `stream: true` requests aren't supported by the middleware (it buffers the
  full response body to read the completion text back out) — not needed for
  this workshop, so it's left unhandled rather than passed through.
- Request/response text is truncated to 4000 chars per field before being
  attached as a span attribute.
- vLLM's own tracing only covers request-level spans inside vLLM itself; there's
  nothing upstream (the agent side) or downstream to propagate trace context
  to yet, since vLLM is the whole app here.
