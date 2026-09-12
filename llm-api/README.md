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
Test it with, e.g.:

```
curl $URL/v1/completions -H 'content-type: application/json' -d '{
  "model": "base",
  "prompt": "The best way to learn a new programming language is",
  "max_tokens": 40
}'
```

### Persistent deploy

```
modal deploy app.py
```

Still to do:
- custom domain (`llms-from-the-top.jessitron.com`) in front of the Modal URL
- `x-api-key` auth and `use-this-model-please` header routing (base vs. trained model)
- a second, chat/instruction-tuned model for the "trained" path
- OpenTelemetry → Honeycomb telemetry

## Telemetry

This app uses (will use) OpenTelemetry to send data to Honeycomb.
