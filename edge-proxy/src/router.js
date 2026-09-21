/**
 * Routing, auth, and Anthropic-translation logic for the edge proxy — kept
 * free of any `@microlabs/otel-cf-workers` / `cloudflare:` imports so it can
 * run and be tested under plain Node (see index.test.js). index.js imports
 * this and wraps it with the OTel instrumentation and Workers-only wiring.
 */
import { trace } from "@opentelemetry/api";

const DEFAULT_MAX_TOKENS = 200;

export function checkAuth(request, env) {
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

export async function fetchUpstream(input, init) {
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
export async function routeToAnthropic(body, incoming, env) {
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

  // gen_ai.* attributes here follow OTel's GenAI semantic conventions, which
  // Honeycomb's cost calculator (docs.honeycomb.io/investigate/observe/llm-cost)
  // reads directly: operation name, provider, model, and token usage.
  const span = trace.getActiveSpan();
  span?.setAttribute("gen_ai.operation.name", "chat");
  span?.setAttribute("gen_ai.provider.name", "anthropic");
  span?.setAttribute("gen_ai.request.model", ANTHROPIC_MODEL);

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
  span?.setAttribute("gen_ai.response.model", anthropicResponse.model);
  if (anthropicResponse.usage?.input_tokens !== undefined) {
    span?.setAttribute("gen_ai.usage.input_tokens", anthropicResponse.usage.input_tokens);
  }
  if (anthropicResponse.usage?.output_tokens !== undefined) {
    span?.setAttribute("gen_ai.usage.output_tokens", anthropicResponse.usage.output_tokens);
  }
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

export const VALID_MODELS = ["base", "chat", "better", "haiku"];

export async function routeToBackend(request, env) {
  const incoming = new URL(request.url);

  let body;
  let raw;
  if (request.method === "POST") {
    raw = await request.text();
    if (raw === "") {
      return new Response(
        `You POSTed with no body. Send JSON like this:\n\n` +
          `curl ${incoming.origin}/v1/chat/completions \\\n` +
          `  -X POST -H "x-api-key: <your key>" -H "content-type: application/json" \\\n` +
          `  -d '{"messages": [{"role": "user", "content": "hi"}]}'\n`,
        { status: 400 },
      );
    }
    try {
      body = JSON.parse(raw);
    } catch (err) {
      return new Response(
        `Invalid JSON in request body: ${err.message}\nGot: ${raw}`,
        { status: 400 },
      );
    }
  }

  if (body?.model !== undefined && !VALID_MODELS.includes(body.model)) {
    return new Response(
      `Unknown model "${body.model}". Valid values are: ${VALID_MODELS.join(", ")} (or omit "model" for the default chat model).`,
      { status: 400 },
    );
  }

  if (incoming.pathname === "/v1/chat/completions") {
    if (body?.messages === undefined) {
      return new Response(
        `/v1/chat/completions requires a "messages" field in the request body.`,
        { status: 400 },
      );
    }
    if (!Array.isArray(body.messages)) {
      return new Response(
        `"messages" must be an array of {role, content} objects, got: ${JSON.stringify(body.messages)}`,
        { status: 400 },
      );
    }
  }

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
  } else if (request.method === "POST") {
    // request.text() above already drained the body stream, so re-reading it
    // via `new Request(upstream, request)` would throw "This ReadableStream
    // is disturbed" — reuse the already-read `raw` text instead.
    upstreamRequest = new Request(upstream, {
      method: request.method,
      headers: request.headers,
      body: raw || undefined,
    });
  } else {
    upstreamRequest = new Request(upstream, request);
  }
  upstreamRequest.headers.set("host", upstream.hostname);

  return fetchUpstream(upstreamRequest);
}
