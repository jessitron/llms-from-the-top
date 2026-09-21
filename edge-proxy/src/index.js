/**
 * Front door for llms-from-the-top.jessitron.com.
 *
 * Routes to one of three Modal-hosted vLLM backends (base, chat, or better
 * model) by the request body's `model` field, defaulting to the chat model.
 * `model: "haiku"` instead calls the real Anthropic API — a workshop backup
 * for when Modal is being Modal (see routeToAnthropic). Requires an
 * `x-api-key` header matching the API_KEY secret — see checkAuth below.
 * Set it with `wrangler secret put API_KEY`.
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
 * "vort") are carried as OTel Baggage rather than plain headers, via the
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

const DEFAULT_MAX_TOKENS = 200;

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

function checkAuth(request, env) {
  const key = request.headers.get("x-api-key");
  if (key === null) {
    return new Response(
      "Unauthorized: missing x-api-key header. Ask Jess for the value.",
      { status: 401 },
    );
  }
  if (key !== env.API_KEY) {
    return new Response(
      "Unauthorized: wrong x-api-key value. Ask Jess for the right value.",
      { status: 401 },
    );
  }
  return null;
}

async function fetchUpstream(input, init) {
  try {
    return await fetch(input, { ...init, signal: AbortSignal.timeout(15_000) });
  } catch (err) {
    if (err.name === "TimeoutError") {
      return new Response(
        "Backend didn't respond in time — it's probably cold-starting. Try again in like 2 minutes.",
        { status: 504 },
      );
    }
    throw err;
  }
}

const ANTHROPIC_MODEL = "claude-haiku-4-5-20251001";
const ANTHROPIC_MAX_TOKENS = 1024;

// Anthropic's Messages API has no OpenAI-compatible endpoint, so this
// translates request and response shapes to match the vLLM backends'
// /v1/chat/completions — the caller (see examples/2-chat) can't tell which
// backend answered.
async function routeToAnthropic(body, incoming, env) {
  if (incoming.pathname !== "/v1/chat/completions") {
    return new Response(
      `model "haiku" only supports /v1/chat/completions, got ${incoming.pathname}`,
      { status: 400 },
    );
  }

  const messages = [];
  let system;
  for (const message of body.messages) {
    if (message.role === "system") system = message.content;
    else messages.push(message);
  }

  const anthropicRequest = {
    model: ANTHROPIC_MODEL,
    max_tokens: body.max_tokens ?? ANTHROPIC_MAX_TOKENS,
    messages,
    ...(system !== undefined ? { system } : {}),
  };

  const response = await fetchUpstream("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(anthropicRequest),
  });
  if (!response.ok) return response;

  const anthropicResponse = await response.json();
  const content = anthropicResponse.content?.map((block) => block.text ?? "").join("") ?? "";
  return Response.json({
    id: anthropicResponse.id,
    model: anthropicResponse.model,
    choices: [
      {
        index: 0,
        message: { role: "assistant", content },
        finish_reason: anthropicResponse.stop_reason,
      },
    ],
    usage: {
      prompt_tokens: anthropicResponse.usage?.input_tokens,
      completion_tokens: anthropicResponse.usage?.output_tokens,
      total_tokens:
        (anthropicResponse.usage?.input_tokens ?? 0) + (anthropicResponse.usage?.output_tokens ?? 0),
    },
  });
}

async function routeToBackend(request, env) {
  const incoming = new URL(request.url);

  let body;
  if (request.method === "POST") body = await request.json();

  if (body?.model === "haiku") return routeToAnthropic(body, incoming, env);

  const backendUrl =
    body?.model === "base"
      ? env.BASE_BACKEND_URL
      : body?.model === "better"
        ? env.BETTER_BACKEND_URL
        : env.CHAT_BACKEND_URL;
  const upstream = new URL(backendUrl);
  upstream.pathname = incoming.pathname;
  upstream.search = incoming.search;

  let upstreamRequest;
  if (body) {
    if (body.model === undefined) body.model = "chat";
    if (incoming.pathname === "/v1/completions" && body.max_tokens === undefined) {
      body.max_tokens = DEFAULT_MAX_TOKENS;
    }
    upstreamRequest = new Request(upstream, {
      method: request.method,
      headers: request.headers,
      body: JSON.stringify(body),
    });
  } else {
    upstreamRequest = new Request(upstream, request);
  }
  upstreamRequest.headers.set("host", upstream.hostname);

  return fetchUpstream(upstreamRequest);
}

const handler = {
  async fetch(request, env) {
    const authError = checkAuth(request, env);
    if (authError) return authError;

    const conversationId = request.headers.get("x-conversation-id") || crypto.randomUUID();
    const agentName = request.headers.get("x-agent-name") || "vort";
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
