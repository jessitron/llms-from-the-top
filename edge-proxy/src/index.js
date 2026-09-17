/**
 * Front door for llms-from-the-top.jessitron.com.
 *
 * Proxies everything straight through to the Modal-hosted vLLM server. It's
 * the seam where request-level logic (x-api-key auth, base-vs-trained model
 * routing by header) gets added later — see the yaks nested under "custom
 * domain" in this repo's `yx list`.
 *
 * Wrapped with `instrument()` from @microlabs/otel-cf-workers (Honeycomb's
 * recommended Workers OTel library — it doesn't need Node polyfills, unlike
 * the standard `@opentelemetry/sdk-trace-node` package). It creates a root
 * span per request and patches the global `fetch` so the outgoing request to
 * the Modal backend below carries a `traceparent` header automatically —
 * that's what lets this span and llm-api's `otel_middleware.py` span (which
 * now extracts that header, see its docstring) land in the same trace.
 */
import { instrument } from "@microlabs/otel-cf-workers";

const handler = {
  async fetch(request, env) {
    const incoming = new URL(request.url);
    const upstream = new URL(env.BACKEND_URL);
    upstream.pathname = incoming.pathname;
    upstream.search = incoming.search;

    let upstreamRequest;
    if (incoming.pathname === "/v1/completions" && request.method === "POST") {
      // vLLM defaults max_tokens to the OpenAI API's own default of 16 when
      // the client omits it, which makes completions look truncated. The
      // workshop examples are meant to stay minimal, so default it here
      // instead — callers can still override it by sending their own value.
      const body = await request.json();
      if (body.max_tokens === undefined) body.max_tokens = 100;
      upstreamRequest = new Request(upstream, {
        method: request.method,
        headers: request.headers,
        body: JSON.stringify(body),
      });
    } else {
      upstreamRequest = new Request(upstream, request);
    }
    upstreamRequest.headers.set("host", upstream.hostname);
    return fetch(upstreamRequest);
  },
};

const config = (env) => ({
  exporter: {
    url: "https://api.honeycomb.io/v1/traces",
    headers: { "x-honeycomb-team": env.HONEYCOMB_API_KEY },
  },
  service: { name: "llms-from-the-top-edge-proxy" },
});

export default instrument(handler, config);
