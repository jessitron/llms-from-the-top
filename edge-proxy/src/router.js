/**
 * Routing, auth, and Anthropic-translation logic for the edge proxy — kept
 * free of any `@microlabs/otel-cf-workers` / `cloudflare:` imports so it can
 * run and be tested under plain Node (see index.test.js). index.js imports
 * this and wraps it with the OTel instrumentation and Workers-only wiring.
 */
import { trace } from "@opentelemetry/api";

const DEFAULT_MAX_TOKENS = 200;

// Honeycomb's open sandbox instance — not the usual us.honeycomb.io — with
// its own team ("sandbox") and a "workshop" environment set up so people can
// see the data without creating an account. The dataset matches this
// service's OTel service.name (see index.js's `config`), since Honeycomb
// names a dataset after the service that first writes to it.
const HONEYCOMB_TRACE_BASE =
  "https://play.honeycomb.io/sandbox/environments/workshop/datasets/llms-from-the-top-edge-proxy/trace";

// Bonus field on every chat response: a direct link to this request's trace
// in Honeycomb, so participants can click straight from a response into the
// trace that produced it. trace_start_ts/trace_end_ts just bound the search
// window generously around "now" — they don't need to be exact.
function traceLink(span) {
  const traceId = span?.spanContext().traceId;
  if (traceId === undefined) return undefined;
  const nowSeconds = Math.floor(Date.now() / 1000);
  const params = new URLSearchParams({
    trace_id: traceId,
    span: span.spanContext().spanId,
    trace_start_ts: nowSeconds - 60,
    trace_end_ts: nowSeconds + 60,
  });
  return `${HONEYCOMB_TRACE_BASE}?${params}`;
}

// Honeycomb's Gen AI message format (see genai-message-format.md): each
// message becomes { role, parts: [...] }, JSON-encoded as a single string
// per gen_ai.input.messages / gen_ai.output.messages attribute. Note the
// text part field is `content`, not `text`.
//
// This is called with messages in either of two shapes, depending on the
// caller: OpenAI-shaped (role/content string, plus optional tool_calls, or
// role "tool" with tool_call_id) from routeToBackend, and Anthropic-shaped
// (content is a string OR an array of text/tool_use/tool_result blocks)
// from routeToAnthropic. A message whose content is an array falls outside
// the plain-string case this used to assume, and was silently turned into
// an empty text part instead of a tool_call/tool_call_response part.
function genAiMessagePart(message) {
  if (message.role === "tool") {
    return {
      role: "tool",
      parts: [
        {
          type: "tool_call_response",
          id: message.tool_call_id,
          response: typeof message.content === "string" ? message.content : JSON.stringify(message.content),
        },
      ],
    };
  }

  if (message.tool_calls !== undefined) {
    const parts = [];
    if (typeof message.content === "string" && message.content !== "") {
      parts.push({ type: "text", content: message.content });
    }
    for (const call of message.tool_calls) {
      parts.push({ type: "tool_call", id: call.id, name: call.function.name, arguments: call.function.arguments });
    }
    return { role: message.role, parts };
  }

  if (Array.isArray(message.content)) {
    return {
      role: message.role,
      parts: message.content.map((block) => {
        if (block.type === "tool_use") {
          return { type: "tool_call", id: block.id, name: block.name, arguments: JSON.stringify(block.input) };
        }
        if (block.type === "tool_result") {
          return {
            type: "tool_call_response",
            id: block.tool_use_id,
            response: typeof block.content === "string" ? block.content : JSON.stringify(block.content),
          };
        }
        return { type: "text", content: block.text ?? "" };
      }),
    };
  }

  return {
    role: message.role,
    parts: [{ type: "text", content: typeof message.content === "string" ? message.content : "" }],
  };
}

function genAiInputMessages(messages) {
  return JSON.stringify(messages.map(genAiMessagePart));
}

// Plain-text pair for easy grouping in Honeycomb (jess.last_input /
// jess.completion), alongside the structured gen_ai.* attributes above.
// jess.last_input is whatever the LLM is responding to: usually the most
// recent user text, but when the request ends in tool results, it's those
// tool calls and (the start of) their responses instead.
function lastInputText(messages) {
  return lastToolResponseText(messages) ?? lastUserInputText(messages);
}

const TOOL_RESPONSE_PREVIEW_CHARS = 200;

// If the conversation ends with tool results — OpenAI-shaped role:"tool"
// messages, or an Anthropic-shaped role:"user" message of tool_result
// blocks — describe each as `name(arguments) → response`, looking up the
// matching call by id in the earlier assistant messages.
function lastToolResponseText(messages) {
  const results = [];
  for (const message of [...messages].reverse()) {
    if (message.role === "tool") {
      results.unshift({ id: message.tool_call_id, content: message.content });
      continue;
    }
    if (message.role === "user" && Array.isArray(message.content)) {
      const blocks = message.content.filter((block) => block.type === "tool_result");
      results.unshift(...blocks.map((block) => ({ id: block.tool_use_id, content: block.content })));
    }
    break;
  }
  if (results.length === 0) return undefined;

  const calls = {};
  for (const message of messages) {
    for (const call of message.tool_calls ?? []) {
      calls[call.id] = { name: call.function.name, arguments: call.function.arguments };
    }
    if (Array.isArray(message.content)) {
      for (const block of message.content) {
        if (block.type === "tool_use") calls[block.id] = { name: block.name, arguments: JSON.stringify(block.input) };
      }
    }
  }

  return results
    .map(({ id, content }) => {
      const call = calls[id];
      const callText = call === undefined ? `tool call ${id}` : `${call.name}(${call.arguments})`;
      const response = typeof content === "string" ? content : JSON.stringify(content);
      const preview =
        response.length > TOOL_RESPONSE_PREVIEW_CHARS ? `${response.slice(0, TOOL_RESPONSE_PREVIEW_CHARS)}…` : response;
      return `${callText} → ${preview}`;
    })
    .join("\n");
}

// Finds the most recent user message and pulls out its text, handling both
// the OpenAI string-content shape and the Anthropic text-block-array shape.
function lastUserInputText(messages) {
  for (const message of [...messages].reverse()) {
    if (message.role !== "user") continue;
    if (typeof message.content === "string") return message.content;
    if (Array.isArray(message.content)) {
      const text = message.content
        .filter((block) => block.type === "text")
        .map((block) => block.text ?? block.content ?? "")
        .join("");
      // Anthropic represents tool results as role:"user" messages whose
      // content is tool_result blocks, not typed text. Skip those and keep
      // looking further back for what the human actually typed.
      if (text !== "") return text;
    }
  }
  return undefined;
}

function genAiOutputMessages(message, finishReason) {
  const part = genAiMessagePart(message);
  if (finishReason !== undefined) part.finish_reason = finishReason;
  return JSON.stringify([part]);
}

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

// OpenAI's tools array ({type: "function", function: {name, description,
// parameters}}) vs. Anthropic's ({name, description, input_schema}).
function toAnthropicTools(tools) {
  if (tools === undefined) return undefined;
  return tools.map((tool) => ({
    name: tool.function.name,
    description: tool.function.description,
    input_schema: tool.function.parameters,
  }));
}

// Honeycomb's gen_ai.tool.definitions attribute (OTel GenAI semconv) wants
// a flattened {type: "function", name, description, parameters} shape —
// not OpenAI's nested {type: "function", function: {name, ...}}.
function genAiToolDefinitions(tools) {
  if (tools === undefined) return undefined;
  return JSON.stringify(
    tools.map((tool) => ({
      type: "function",
      name: tool.function.name,
      description: tool.function.description,
      parameters: tool.function.parameters,
    })),
  );
}

// OpenAI's tool_choice ("auto" | "none" | "required" | {type: "function",
// function: {name}}) vs. Anthropic's ({type: "auto" | "none" | "any" | "tool", name}).
function toAnthropicToolChoice(toolChoice) {
  if (toolChoice === undefined) return undefined;
  if (toolChoice === "auto") return { type: "auto" };
  if (toolChoice === "none") return { type: "none" };
  if (toolChoice === "required") return { type: "any" };
  return { type: "tool", name: toolChoice.function.name };
}

// Translates one OpenAI-shaped message into Anthropic's shape. An assistant
// message with tool_calls becomes text + tool_use content blocks; a tool
// message (the result of running one) becomes a user message carrying a
// tool_result block. Plain text messages pass through unchanged.
function toAnthropicMessage(message) {
  if (message.role === "tool") {
    return {
      role: "user",
      content: [{ type: "tool_result", tool_use_id: message.tool_call_id, content: message.content }],
    };
  }
  if (message.role === "assistant" && message.tool_calls !== undefined) {
    const content = [];
    if (message.content) content.push({ type: "text", text: message.content });
    for (const call of message.tool_calls) {
      content.push({ type: "tool_use", id: call.id, name: call.function.name, input: JSON.parse(call.function.arguments) });
    }
    return { role: "assistant", content };
  }
  return message;
}

// Anthropic's stop_reason "tool_use" is OpenAI's finish_reason "tool_calls";
// every other stop_reason (end_turn, max_tokens, ...) is passed through as-is.
function toOpenAiFinishReason(stopReason) {
  return stopReason === "tool_use" ? "tool_calls" : stopReason;
}

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
    else messages.push(toAnthropicMessage(message));
  }

  const tools = toAnthropicTools(body.tools);
  const toolChoice = toAnthropicToolChoice(body.tool_choice);

  const anthropicRequest = {
    model: ANTHROPIC_MODEL,
    max_tokens: body.max_tokens ?? ANTHROPIC_MAX_TOKENS,
    messages,
    ...(system !== undefined ? { system } : {}),
    ...(tools !== undefined ? { tools } : {}),
    ...(toolChoice !== undefined ? { tool_choice: toolChoice } : {}),
  };

  // gen_ai.* attributes here follow OTel's GenAI semantic conventions, which
  // Honeycomb's cost calculator (docs.honeycomb.io/investigate/observe/llm-cost)
  // reads directly: operation name, provider, model, and token usage.
  const span = trace.getActiveSpan();
  span?.setAttribute("gen_ai.operation.name", "chat");
  span?.setAttribute("gen_ai.provider.name", "anthropic");
  span?.setAttribute("gen_ai.request.model", ANTHROPIC_MODEL);
  // Raw copy of what we're about to translate, so a translation bug (like the
  // one that motivated this) shows up as a visible mismatch in Honeycomb
  // instead of just quietly blank gen_ai.input.messages parts.
  span?.setAttribute("app.raw_input_messages", JSON.stringify(messages));
  span?.setAttribute("gen_ai.input.messages", genAiInputMessages(messages));
  const lastInput = lastInputText(messages);
  if (lastInput !== undefined) span?.setAttribute("jess.last_input", lastInput);
  if (system !== undefined) {
    span?.setAttribute("gen_ai.system_instructions", JSON.stringify([{ type: "text", content: system }]));
  }
  if (body.tools !== undefined) {
    span?.setAttribute("gen_ai.tool.definitions", genAiToolDefinitions(body.tools));
  }

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
  const content = anthropicResponse.content
    ?.filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("") ?? "";
  const toolCalls = anthropicResponse.content
    ?.filter((block) => block.type === "tool_use")
    .map((block) => ({
      id: block.id,
      type: "function",
      function: { name: block.name, arguments: JSON.stringify(block.input) },
    })) ?? [];
  const finishReason = toOpenAiFinishReason(anthropicResponse.stop_reason);
  span?.setAttribute("app.raw_output_message", JSON.stringify(anthropicResponse.content ?? []));
  span?.setAttribute("jess.completion", content);
  span?.setAttribute(
    "gen_ai.output.messages",
    genAiOutputMessages(
      { role: "assistant", content, ...(toolCalls.length > 0 ? { tool_calls: toolCalls } : {}) },
      finishReason,
    ),
  );
  return Response.json({
    id: anthropicResponse.id,
    model: anthropicResponse.model,
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content,
          ...(toolCalls.length > 0 ? { tool_calls: toolCalls } : {}),
        },
        finish_reason: finishReason,
      },
    ],
    usage: {
      prompt_tokens: anthropicResponse.usage?.input_tokens,
      completion_tokens: anthropicResponse.usage?.output_tokens,
      total_tokens:
        (anthropicResponse.usage?.input_tokens ?? 0) + (anthropicResponse.usage?.output_tokens ?? 0),
    },
    trace_link: traceLink(span),
  });
}

// Model aliases that proxy straight through to OpenAI's own
// /v1/chat/completions (no translation needed, see below).
const OPENAI_MODELS = {
  luna: "gpt-4o-mini",
  nano: "gpt-4.1-nano",
};

// Unlike Anthropic's Messages API, OpenAI's /v1/chat/completions already
// matches the OpenAI-shaped request/response this proxy speaks — messages,
// tools, tool_choice, and the response's choices[0].message all pass through
// unchanged. So there's no translation step here, just a model swap, auth,
// and the same gen_ai.* telemetry as routeToBackend below.
export async function routeToOpenAI(body, incoming, env) {
  const openAiModel = OPENAI_MODELS[body.model];
  if (incoming.pathname !== "/v1/chat/completions") {
    return new Response(
      `model "${body.model}" only supports /v1/chat/completions, got ${incoming.pathname}`,
      { status: 400 },
    );
  }

  const span = trace.getActiveSpan();
  span?.setAttribute("gen_ai.operation.name", "chat");
  span?.setAttribute("gen_ai.provider.name", "openai");
  span?.setAttribute("gen_ai.request.model", openAiModel);
  span?.setAttribute("app.raw_input_messages", JSON.stringify(body.messages));
  span?.setAttribute("gen_ai.input.messages", genAiInputMessages(body.messages));
  const lastInput = lastInputText(body.messages);
  if (lastInput !== undefined) span?.setAttribute("jess.last_input", lastInput);
  if (body.tools !== undefined) {
    span?.setAttribute("gen_ai.tool.definitions", genAiToolDefinitions(body.tools));
  }

  const response = await fetchUpstream("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${env.OPENAI_API_KEY}`,
    },
    body: JSON.stringify({ ...body, model: openAiModel }),
  });
  if (!response.ok) return response;

  const openAiResponse = await response.json();
  const choice = openAiResponse.choices?.[0];
  if (choice?.message) {
    span?.setAttribute("app.raw_output_message", JSON.stringify(choice.message));
    span?.setAttribute("gen_ai.output.messages", genAiOutputMessages(choice.message, choice.finish_reason));
    if (typeof choice.message.content === "string") {
      span?.setAttribute("jess.completion", choice.message.content);
    }
  }
  if (openAiResponse.model) span?.setAttribute("gen_ai.response.model", openAiResponse.model);
  if (openAiResponse.usage?.prompt_tokens !== undefined) {
    span?.setAttribute("gen_ai.usage.input_tokens", openAiResponse.usage.prompt_tokens);
  }
  if (openAiResponse.usage?.completion_tokens !== undefined) {
    span?.setAttribute("gen_ai.usage.output_tokens", openAiResponse.usage.completion_tokens);
  }
  return Response.json({ ...openAiResponse, trace_link: traceLink(span) }, { status: response.status });
}

export const VALID_MODELS = ["base", "chat", "better", "haiku", "luna", "nano"];

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
  if (body?.model === "luna" || body?.model === "nano") return routeToOpenAI(body, incoming, env);

  const span = trace.getActiveSpan();
  const isChat = incoming.pathname === "/v1/chat/completions" && body?.messages !== undefined;
  if (isChat) {
    span?.setAttribute("gen_ai.operation.name", "chat");
    span?.setAttribute("gen_ai.request.model", body.model ?? "chat");
    span?.setAttribute("app.raw_input_messages", JSON.stringify(body.messages));
    span?.setAttribute("gen_ai.input.messages", genAiInputMessages(body.messages));
    const lastInput = lastInputText(body.messages);
    if (lastInput !== undefined) span?.setAttribute("jess.last_input", lastInput);
    if (body.tools !== undefined) {
      span?.setAttribute("gen_ai.tool.definitions", genAiToolDefinitions(body.tools));
    }
  }

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

  const response = await fetchUpstream(upstreamRequest);
  if (!isChat || !response.ok) return response;

  const responseBody = await response.json();
  const choice = responseBody.choices?.[0];
  if (choice?.message) {
    span?.setAttribute("app.raw_output_message", JSON.stringify(choice.message));
    span?.setAttribute("gen_ai.output.messages", genAiOutputMessages(choice.message, choice.finish_reason));
    if (typeof choice.message.content === "string") {
      span?.setAttribute("jess.completion", choice.message.content);
    }
  }
  if (responseBody.model) span?.setAttribute("gen_ai.response.model", responseBody.model);
  if (responseBody.usage?.prompt_tokens !== undefined) {
    span?.setAttribute("gen_ai.usage.input_tokens", responseBody.usage.prompt_tokens);
  }
  if (responseBody.usage?.completion_tokens !== undefined) {
    span?.setAttribute("gen_ai.usage.output_tokens", responseBody.usage.completion_tokens);
  }
  return Response.json({ ...responseBody, trace_link: traceLink(span) }, { status: response.status });
}
