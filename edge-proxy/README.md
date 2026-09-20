# Edge proxy for llms-from-the-top.jessitron.com

A Cloudflare Worker that fronts the Modal-hosted vLLM API at a friendly domain.

## Why this exists

Modal's own custom-domain feature (`custom_domains=` on the web endpoint
decorator) requires a Team or Enterprise Modal plan. This Worker gets the
domain working without that, and it's also the natural place to add other
request-level logic later — `x-api-key` auth, etc. (see the yaks nested
under "custom domain" via `yx list`).

It forwards every request to one of three Modal backend URLs in
`wrangler.toml` — `BASE_BACKEND_URL` if the request body's `"model"` is
`"base"`, `BETTER_BACKEND_URL` if it's `"better"`, `CHAT_BACKEND_URL`
otherwise — rewriting the Host header so Modal's edge routes it correctly.
`../llm-api` runs each model as its own Modal function/URL (see its
README), so this is the seam that lets callers pick a model by name
instead of knowing which URL serves it.

## Telemetry

Wrapped with `instrument()` from
[`@microlabs/otel-cf-workers`](https://github.com/evanderkoogh/otel-cf-workers)
(service `llms-from-the-top-edge-proxy`), which creates a root span per
request and patches the global `fetch`, so the proxied request to the Modal
backend carries a `traceparent` header automatically. `llm-api`'s
`otel_middleware.py` extracts that header, so this span, the llm-api HTTP
span, and vLLM's own engine span all land in one trace — see
`../llm-api/README.md`'s Telemetry section for the rest of the chain.

## One-time setup

1. `npm install -g wrangler` (or use `npx wrangler`)
2. `wrangler login` — opens a browser to authorize against your Cloudflare
   account that owns the jessitron.com zone.
3. `npm install` — pulls in `@microlabs/otel-cf-workers`.
4. `wrangler secret put HONEYCOMB_API_KEY` — same Honeycomb API key used by
   `llm-api` (see `modal secret create honeycomb ...` in `../llm-api/README.md`).

No DNS step needed beyond that: `wrangler.toml` uses `custom_domain = true`
on the route, which tells Cloudflare to manage the DNS record itself as a
"Workers Custom Domain." `wrangler deploy` creates it automatically on first
deploy — nothing to add by hand in the dashboard, and the dashboard will
refuse to let you add a conflicting record manually once it exists ("A DNS
record managed by Workers already exists on that host").

## Deploy

```
cd edge-proxy
wrangler deploy
```

This publishes the Worker and attaches
`llms-from-the-top.jessitron.com` as a custom domain, per `wrangler.toml`.
First deploy can take a minute or two for the domain/cert to become active.

## Test

```
curl https://llms-from-the-top.jessitron.com/v1/completions \
  -H 'content-type: application/json' \
  -d '{"model": "base", "prompt": "Hello", "max_tokens": 5}'

curl https://llms-from-the-top.jessitron.com/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model": "chat", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 5}'

curl https://llms-from-the-top.jessitron.com/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model": "better", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 5}'
```

## If the Modal backend URLs change

Update `BASE_BACKEND_URL`, `CHAT_BACKEND_URL`, and/or `BETTER_BACKEND_URL`
in `wrangler.toml` and redeploy. The base/chat values came from `./deploy`'s
output in `../llm-api`, and the better value from `./deploy-better`'s.
