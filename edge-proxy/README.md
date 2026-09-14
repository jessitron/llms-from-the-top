# Edge proxy for llms-from-the-top.jessitron.com

A Cloudflare Worker that fronts the Modal-hosted vLLM API at a friendly domain.

## Why this exists

Modal's own custom-domain feature (`custom_domains=` on the web endpoint
decorator) requires a Team or Enterprise Modal plan. This Worker gets the
domain working without that, and it's also the natural place to add
request-level logic later — `x-api-key` auth, routing to a "trained" model by
header, etc. (see the yaks nested under "custom domain" via `yx list`).

Right now it does nothing but forward every request to the Modal backend
URL in `wrangler.toml`'s `BACKEND_URL` var, rewriting the Host header so
Modal's edge routes it correctly.

## One-time setup

1. `npm install -g wrangler` (or use `npx wrangler`)
2. `wrangler login` — opens a browser to authorize against your Cloudflare
   account that owns the jessitron.com zone.

## Deploy

```
cd edge-proxy
wrangler deploy
```

This publishes the Worker and attaches the route
`llms-from-the-top.jessitron.com/*` from `wrangler.toml`. First deploy can
take a minute or two for the route/DNS to become active.

## Test

```
curl https://llms-from-the-top.jessitron.com/v1/completions \
  -H 'content-type: application/json' \
  -d '{"model": "base", "prompt": "Hello", "max_tokens": 5}'
```

## If the Modal backend URL changes

Update `BACKEND_URL` in `wrangler.toml` and redeploy. The current value came
from `modal deploy app.py`'s output in `../llm-api`.
