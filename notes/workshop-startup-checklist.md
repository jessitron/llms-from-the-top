# Before the workshop: what to start up

[] push this repo

Two independent Modal apps, deployed and stopped separately.

## 1. base + chat pair (`llm-api/app.py`)

```
cd llm-api
./deploy
```

- Deploys `mistralai/Mistral-7B-v0.1` (`base`) and
  `mistralai/Mistral-7B-Instruct-v0.1` (`chat`), each on its own A10G.
- Sends a warm-up request to `chat` only, so the GPU spin-up/model load
  happens now, not on the first participant's request. `base` is _not_
  warmed up automatically — it isn't always used in a given session.
- If this session will use the base model (stage `1-completions`), warm it
  up manually before the workshop by running `vort_1a.rb` once:
  `ruby examples/1-completions/vort_1a.rb` (type anything at the `vort>`
  prompt). This sends a real request through the full stack
  (edge-proxy → llm-api) and eats the cold start.
- Stop with `./stop` when done (both models together).

## 2. better model (`llm-api/app-better.py`)

```
cd llm-api
./deploy-better
```

- Deploys `mistralai/Mistral-Small-3.2-24B-Instruct-2506` (`better`) on an
  A100-80GB — separate app, separate lifecycle, so stopping/starting it
  doesn't touch the base/chat pair.
- Sends its own warm-up request.
- Stop with `./stop-better` when done.

## Cost while running

Modal bills per second of actual GPU uptime (idle-scale-down is
`scaledown_window = 30 min` on all three functions, so leaving them deployed
between short gaps is fine — cost accrues only while a container is actually
up):

| Function       | GPU       | ~$/hour |
| -------------- | --------- | ------- |
| `serve`        | A10G      | ~$1.10  |
| `serve_chat`   | A10G      | ~$1.10  |
| `serve_better` | A100-80GB | ~$2.50  |

(A10G rate from Modal's pricing page at the time `app.py` was written;
A100-80GB and the two other candidates checked 2026-09-20 — L40S ~$1.95/hr
was considered for the "better" model but doesn't have enough headroom
above the 24B model's ~48GB of bf16 weights once vLLM's KV cache is added.)

## One-time setup (already done, unless this is a new Modal account)

- `modal` CLI authenticated (`setup-modal-account.sh` if starting fresh)

Traces/logs go straight to the OTel collector at
`workshop.jessitron.honeydemo.io` — no Honeycomb secret needed on the Modal
side anymore.

## Before leaving each session

`./stop` and `./stop-better` — don't rely on `scaledown_window` alone for
multi-hour idle gaps (e.g. overnight between workshop days).

# Shutting down after the workshop

[] Turn off the collector in my orion cluster (jessitron/infra)

[] Turn off both modal apps with ./stop

[] turn off the cloudflare worker in edge-proxy (or at least make the API key obscure)

[] tell modal not to bill me anymore

[] turn off cloudflare upgraded plan

[] track expenses for taxes
