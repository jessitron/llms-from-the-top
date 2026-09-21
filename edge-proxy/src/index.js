/**
 * Front door for llms-from-the-top.jessitron.com.
 *
 * Routes to one of three Modal-hosted vLLM backends (base, chat, or better
 * model) by the request body's `model` field, defaulting to the chat model.
 * `model: "haiku"` and `model: "luna"` instead call the real Anthropic and
 * OpenAI APIs directly — workshop backups for when Modal is being Modal
 * (see routeToAnthropic / routeToOpenAI in router.js). Requires
 * an `x-api-key` header matching the API_KEY secret — see checkAuth below.
 * Set it with `wrangler secret put API_KEY`.
 *
 * The actual routing/auth/translation logic lives in router.js, kept free of
 * any `cloudflare:`-only imports so it can be unit tested under plain Node
 * (see router.test.js). This file is just the Workers/OTel wiring around it.
 *
 * Wrapped with `instrument()` from @microlabs/otel-cf-workers (Honeycomb's
 * recommended Workers OTel library — it doesn't need Node polyfills, unlike
 * the standard `@opentelemetry/sdk-trace-node` package). It creates a root
 * span per request and patches the global `fetch` so the outgoing request to
 * the Modal backend below carries a `traceparent` header automatically —
 * that's what lets this span and llm-api's `otel_middleware.py` span (which
 * now extracts that header, see its docstring) land in the same trace.
 *
 * gen_ai.conversation.id and gen_ai.agent.name (from the caller's
 * x-conversation-id / x-agent-name headers, the latter defaulting to
 * "secret agent") are carried as OTel Baggage rather than plain headers, via the
 * W3C `baggage` header (also patched onto the outgoing fetch automatically,
 * same as `traceparent`). Baggage lives on the active
 * context rather than one span, so BaggageSpanProcessor below can stamp it
 * (and any other baggage entry) onto every span this worker creates after
 * baggage is set — and llm-api's own baggage span processor does the same
 * for every span it creates. `instrument()` itself starts the root span
 * before calling `handler.fetch` below, i.e. before we've set baggage, so
 * BaggageSpanProcessor's onStart runs too early to catch that one span —
 * hence the direct `setAttribute` call on the active (root) span too.
 */
import { instrument, OTLPExporter, BatchTraceSpanProcessor } from "@microlabs/otel-cf-workers";
import { context, propagation, trace } from "@opentelemetry/api";
import { CompositePropagator, W3CBaggagePropagator, W3CTraceContextPropagator } from "@opentelemetry/core";
import { checkAuth, routeToBackend } from "./router.js";

class BaggageSpanProcessor {
  onStart(span, parentContext) {
    const baggage = propagation.getBaggage(parentContext);
    for (const [key, entry] of baggage?.getAllEntries() ?? []) {
      span.setAttribute(key, entry.value);
    }
  }
  onEnd() {}
  shutdown() {
    return Promise.resolve();
  }
  forceFlush() {
    return Promise.resolve();
  }
}

const WORKSHOP_REPO = "https://github.com/jessitron/llms-from-the-top";

const handler = {
  async fetch(request, env) {
    if (request.method === "GET") return Response.redirect(WORKSHOP_REPO, 302);

    const authError = checkAuth(request, env);
    if (authError) return authError;

    const conversationId = request.headers.get("x-conversation-id") || crypto.randomUUID();
    const agentName = request.headers.get("x-agent-name") || "secret agent";
    const baggage = propagation.createBaggage({
      "gen_ai.conversation.id": { value: conversationId },
      "gen_ai.agent.name": { value: agentName },
    });
    const ctxWithBaggage = propagation.setBaggage(context.active(), baggage);
    trace.getActiveSpan()?.setAttribute("gen_ai.conversation.id", conversationId);
    trace.getActiveSpan()?.setAttribute("gen_ai.agent.name", agentName);

    return context.with(ctxWithBaggage, () => routeToBackend(request, env));
  },
};

const config = (env) => ({
  spanProcessors: [
    new BaggageSpanProcessor(),
    new BatchTraceSpanProcessor(
      new OTLPExporter({
        url: "https://api.honeycomb.io/v1/traces",
        headers: { "x-honeycomb-team": env.HONEYCOMB_API_KEY },
      }),
    ),
  ],
  service: { name: "llms-from-the-top-edge-proxy" },
  propagator: new CompositePropagator({
    propagators: [new W3CTraceContextPropagator(), new W3CBaggagePropagator()],
  }),
});

export default instrument(handler, config);
