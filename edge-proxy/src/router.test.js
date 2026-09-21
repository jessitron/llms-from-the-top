import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// router.js reads the active span via @opentelemetry/api's trace.getActiveSpan(),
// which needs a real async-context manager (not installed here) to work across
// awaits. Mock it with a stub span that just records setAttribute calls.
const { capturedAttributes, fakeSpan } = vi.hoisted(() => {
  const capturedAttributes = {};
  const fakeSpan = {
    setAttribute: (key, value) => {
      capturedAttributes[key] = value;
    },
  };
  return { capturedAttributes, fakeSpan };
});

vi.mock("@opentelemetry/api", async (importOriginal) => {
  const actual = await importOriginal();
  return { ...actual, trace: { ...actual.trace, getActiveSpan: () => fakeSpan } };
});

import { checkAuth, routeToBackend, routeToAnthropic } from "./router.js";

const env = {
  API_KEY: "secret-key",
  ANTHROPIC_API_KEY: "anthropic-secret",
  BASE_BACKEND_URL: "https://base.example.com",
  CHAT_BACKEND_URL: "https://chat.example.com",
  BETTER_BACKEND_URL: "https://better.example.com",
};

function request(path, { method = "POST", body, headers = {} } = {}) {
  return new Request(`https://llms-from-the-top.jessitron.com${path}`, {
    method,
    headers,
    ...(body !== undefined ? { body: typeof body === "string" ? body : JSON.stringify(body) } : {}),
  });
}

describe("checkAuth", () => {
  it("rejects a request with no x-api-key header", async () => {
    const res = checkAuth(request("/v1/chat/completions"), env);
    expect(res.status).toBe(401);
    expect(await res.text()).toMatch(/missing x-api-key/);
  });

  it("rejects a request with the wrong x-api-key", async () => {
    const res = checkAuth(request("/v1/chat/completions", { headers: { "x-api-key": "wrong" } }), env);
    expect(res.status).toBe(401);
    expect(await res.text()).toMatch(/wrong x-api-key/);
  });

  it("allows a request with the correct x-api-key", () => {
    const res = checkAuth(request("/v1/chat/completions", { headers: { "x-api-key": "secret-key" } }), env);
    expect(res).toBeNull();
  });
});

describe("routeToBackend", () => {
  let fetchMock;

  beforeEach(() => {
    fetchMock = vi.fn(async () => Response.json({ ok: true }));
    vi.stubGlobal("fetch", fetchMock);
    for (const key of Object.keys(capturedAttributes)) delete capturedAttributes[key];
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("rejects invalid JSON bodies", async () => {
    const res = await routeToBackend(request("/v1/chat/completions", { body: "{not json" }), env);
    expect(res.status).toBe(400);
    expect(await res.text()).toMatch(/Invalid JSON/);
  });

  it("rejects an unknown model", async () => {
    const res = await routeToBackend(
      request("/v1/chat/completions", { body: { model: "gpt-5", messages: [] } }),
      env,
    );
    expect(res.status).toBe(400);
    expect(await res.text()).toMatch(/Unknown model "gpt-5"/);
  });

  it("requires a messages field on /v1/chat/completions", async () => {
    const res = await routeToBackend(request("/v1/chat/completions", { body: {} }), env);
    expect(res.status).toBe(400);
    expect(await res.text()).toMatch(/requires a "messages" field/);
  });

  it("rejects a non-array messages field", async () => {
    const res = await routeToBackend(
      request("/v1/chat/completions", { body: { messages: "hi" } }),
      env,
    );
    expect(res.status).toBe(400);
    expect(await res.text()).toMatch(/must be an array/);
  });

  it("defaults to the chat backend and fills in model: chat", async () => {
    await routeToBackend(
      request("/v1/chat/completions", { body: { messages: [{ role: "user", content: "hi" }] } }),
      env,
    );
    const [upstreamRequest] = fetchMock.mock.calls[0];
    expect(upstreamRequest.url).toBe("https://chat.example.com/v1/chat/completions");
    const sentBody = await upstreamRequest.clone().json();
    expect(sentBody.model).toBe("chat");
  });

  it("routes model: base to the base backend", async () => {
    await routeToBackend(
      request("/v1/chat/completions", { body: { model: "base", messages: [] } }),
      env,
    );
    const [upstreamRequest] = fetchMock.mock.calls[0];
    expect(upstreamRequest.url).toBe("https://base.example.com/v1/chat/completions");
  });

  it("routes model: better to the better backend", async () => {
    await routeToBackend(
      request("/v1/chat/completions", { body: { model: "better", messages: [] } }),
      env,
    );
    const [upstreamRequest] = fetchMock.mock.calls[0];
    expect(upstreamRequest.url).toBe("https://better.example.com/v1/chat/completions");
  });

  it("fills in a default max_tokens on /v1/completions", async () => {
    await routeToBackend(request("/v1/completions", { body: { prompt: "hi" } }), env);
    const [upstreamRequest] = fetchMock.mock.calls[0];
    const sentBody = await upstreamRequest.clone().json();
    expect(sentBody.max_tokens).toBe(200);
  });

  it("does not override an explicit max_tokens on /v1/completions", async () => {
    await routeToBackend(request("/v1/completions", { body: { prompt: "hi", max_tokens: 42 } }), env);
    const [upstreamRequest] = fetchMock.mock.calls[0];
    const sentBody = await upstreamRequest.clone().json();
    expect(sentBody.max_tokens).toBe(42);
  });

  it("passes through GET-like bodyless requests unchanged", async () => {
    await routeToBackend(request("/v1/models", { method: "GET" }), env);
    const [upstreamRequest] = fetchMock.mock.calls[0];
    expect(upstreamRequest.url).toBe("https://chat.example.com/v1/models");
  });

  it("gives a friendly, actionable error for a bodyless POST", async () => {
    const res = await routeToBackend(request("/", {}), env);
    expect(res.status).toBe(400);
    const text = await res.text();
    expect(text).toMatch(/no body/);
    expect(text).toMatch(/curl .*\/v1\/chat\/completions/);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("returns a 504 when the backend times out", async () => {
    fetchMock.mockRejectedValue(new DOMException("Aborted", "TimeoutError"));
    const res = await routeToBackend(request("/v1/models", { method: "GET" }), env);
    expect(res.status).toBe(504);
    expect(await res.text()).toMatch(/cold-starting/);
  });

  it("sets gen_ai input/output message attributes for a chat completion", async () => {
    fetchMock.mockResolvedValue(
      Response.json({
        model: "chat",
        choices: [{ message: { role: "assistant", content: "hi there" }, finish_reason: "stop" }],
        usage: { prompt_tokens: 3, completion_tokens: 4 },
      }),
    );
    await routeToBackend(
      request("/v1/chat/completions", { body: { messages: [{ role: "user", content: "hi" }] } }),
      env,
    );

    expect(capturedAttributes["gen_ai.operation.name"]).toBe("chat");
    expect(capturedAttributes["gen_ai.request.model"]).toBe("chat");
    expect(JSON.parse(capturedAttributes["gen_ai.input.messages"])).toEqual([
      { role: "user", parts: [{ type: "text", content: "hi" }] },
    ]);
    expect(JSON.parse(capturedAttributes["gen_ai.output.messages"])).toEqual([
      {
        role: "assistant",
        parts: [{ type: "text", content: "hi there" }],
        finish_reason: "stop",
      },
    ]);
    expect(capturedAttributes["gen_ai.usage.input_tokens"]).toBe(3);
    expect(capturedAttributes["gen_ai.usage.output_tokens"]).toBe(4);
  });

  it("captures raw and translated gen_ai messages for an OpenAI-shaped tool call/result exchange", async () => {
    fetchMock.mockResolvedValue(
      Response.json({
        model: "chat",
        choices: [{ message: { role: "assistant", content: "It's 72 and sunny." }, finish_reason: "stop" }],
      }),
    );
    const messages = [
      { role: "user", content: "what's the weather in Chicago?" },
      {
        role: "assistant",
        content: null,
        tool_calls: [
          { id: "call_1", type: "function", function: { name: "get_weather", arguments: '{"city":"Chicago"}' } },
        ],
      },
      { role: "tool", tool_call_id: "call_1", content: "72 and sunny" },
    ];
    await routeToBackend(request("/v1/chat/completions", { body: { messages } }), env);

    expect(JSON.parse(capturedAttributes["app.raw_input_messages"])).toEqual(messages);
    expect(JSON.parse(capturedAttributes["gen_ai.input.messages"])).toEqual([
      { role: "user", parts: [{ type: "text", content: "what's the weather in Chicago?" }] },
      {
        role: "assistant",
        parts: [{ type: "tool_call", id: "call_1", name: "get_weather", arguments: '{"city":"Chicago"}' }],
      },
      { role: "tool", parts: [{ type: "tool_call_response", id: "call_1", response: "72 and sunny" }] },
    ]);
  });

  it("captures raw and translated gen_ai output messages when the response includes tool_calls", async () => {
    fetchMock.mockResolvedValue(
      Response.json({
        model: "chat",
        choices: [
          {
            message: {
              role: "assistant",
              content: null,
              tool_calls: [
                { id: "call_1", type: "function", function: { name: "get_weather", arguments: '{"city":"Chicago"}' } },
              ],
            },
            finish_reason: "tool_calls",
          },
        ],
      }),
    );
    await routeToBackend(
      request("/v1/chat/completions", {
        body: { messages: [{ role: "user", content: "what's the weather in Chicago?" }] },
      }),
      env,
    );

    expect(JSON.parse(capturedAttributes["app.raw_output_message"])).toEqual({
      role: "assistant",
      content: null,
      tool_calls: [
        { id: "call_1", type: "function", function: { name: "get_weather", arguments: '{"city":"Chicago"}' } },
      ],
    });
    expect(JSON.parse(capturedAttributes["gen_ai.output.messages"])).toEqual([
      {
        role: "assistant",
        parts: [{ type: "tool_call", id: "call_1", name: "get_weather", arguments: '{"city":"Chicago"}' }],
        finish_reason: "tool_calls",
      },
    ]);
  });
});

describe("routeToAnthropic", () => {
  let fetchMock;

  beforeEach(() => {
    fetchMock = vi.fn(async () =>
      Response.json({
        id: "msg_123",
        model: "claude-haiku-4-5-20251001",
        content: [{ type: "text", text: "hello there" }],
        stop_reason: "end_turn",
        usage: { input_tokens: 10, output_tokens: 5 },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    for (const key of Object.keys(capturedAttributes)) delete capturedAttributes[key];
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("only supports /v1/chat/completions", async () => {
    const body = { messages: [{ role: "user", content: "hi" }] };
    const incoming = new URL("https://llms-from-the-top.jessitron.com/v1/completions");
    const res = await routeToAnthropic(body, incoming, env);
    expect(res.status).toBe(400);
    expect(await res.text()).toMatch(/only supports \/v1\/chat\/completions/);
  });

  it("splits out the system message and forwards the rest to Anthropic", async () => {
    const body = {
      messages: [
        { role: "system", content: "be nice" },
        { role: "user", content: "hi" },
      ],
    };
    const incoming = new URL("https://llms-from-the-top.jessitron.com/v1/chat/completions");
    await routeToAnthropic(body, incoming, env);

    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://api.anthropic.com/v1/messages");
    expect(init.headers["x-api-key"]).toBe("anthropic-secret");
    const sentBody = JSON.parse(init.body);
    expect(sentBody.system).toBe("be nice");
    expect(sentBody.messages).toEqual([{ role: "user", content: "hi" }]);
    expect(sentBody.max_tokens).toBe(1024);
  });

  it("translates the Anthropic response into OpenAI-completion shape", async () => {
    const body = { messages: [{ role: "user", content: "hi" }] };
    const incoming = new URL("https://llms-from-the-top.jessitron.com/v1/chat/completions");
    const res = await routeToAnthropic(body, incoming, env);
    const json = await res.json();

    expect(json.choices[0].message).toEqual({ role: "assistant", content: "hello there" });
    expect(json.choices[0].finish_reason).toBe("end_turn");
    expect(json.usage).toEqual({ prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 });
  });

  it("passes through a non-ok response from Anthropic unchanged", async () => {
    fetchMock.mockResolvedValue(new Response("rate limited", { status: 429 }));
    const body = { messages: [{ role: "user", content: "hi" }] };
    const incoming = new URL("https://llms-from-the-top.jessitron.com/v1/chat/completions");
    const res = await routeToAnthropic(body, incoming, env);
    expect(res.status).toBe(429);
  });

  it("translates OpenAI tools/tool_choice into Anthropic's shape", async () => {
    const body = {
      messages: [{ role: "user", content: "what's the weather?" }],
      tools: [
        {
          type: "function",
          function: {
            name: "get_weather",
            description: "Get the weather for a city",
            parameters: { type: "object", properties: { city: { type: "string" } } },
          },
        },
      ],
      tool_choice: { type: "function", function: { name: "get_weather" } },
    };
    const incoming = new URL("https://llms-from-the-top.jessitron.com/v1/chat/completions");
    await routeToAnthropic(body, incoming, env);

    const [, init] = fetchMock.mock.calls[0];
    const sentBody = JSON.parse(init.body);
    expect(sentBody.tools).toEqual([
      {
        name: "get_weather",
        description: "Get the weather for a city",
        input_schema: { type: "object", properties: { city: { type: "string" } } },
      },
    ]);
    expect(sentBody.tool_choice).toEqual({ type: "tool", name: "get_weather" });
  });

  it("translates an assistant tool_calls message and a tool-result message into Anthropic's shape", async () => {
    const body = {
      messages: [
        { role: "user", content: "what's the weather in Chicago?" },
        {
          role: "assistant",
          content: null,
          tool_calls: [
            { id: "call_1", type: "function", function: { name: "get_weather", arguments: '{"city":"Chicago"}' } },
          ],
        },
        { role: "tool", tool_call_id: "call_1", content: "72 and sunny" },
      ],
    };
    const incoming = new URL("https://llms-from-the-top.jessitron.com/v1/chat/completions");
    await routeToAnthropic(body, incoming, env);

    const [, init] = fetchMock.mock.calls[0];
    const sentBody = JSON.parse(init.body);
    expect(sentBody.messages).toEqual([
      { role: "user", content: "what's the weather in Chicago?" },
      {
        role: "assistant",
        content: [{ type: "tool_use", id: "call_1", name: "get_weather", input: { city: "Chicago" } }],
      },
      {
        role: "user",
        content: [{ type: "tool_result", tool_use_id: "call_1", content: "72 and sunny" }],
      },
    ]);
  });

  it("translates Anthropic tool_use response blocks into OpenAI tool_calls", async () => {
    fetchMock.mockResolvedValue(
      Response.json({
        id: "msg_456",
        model: "claude-haiku-4-5-20251001",
        content: [
          { type: "text", text: "Let me check that." },
          { type: "tool_use", id: "toolu_1", name: "get_weather", input: { city: "Chicago" } },
        ],
        stop_reason: "tool_use",
        usage: { input_tokens: 10, output_tokens: 5 },
      }),
    );
    const body = { messages: [{ role: "user", content: "what's the weather in Chicago?" }] };
    const incoming = new URL("https://llms-from-the-top.jessitron.com/v1/chat/completions");
    const res = await routeToAnthropic(body, incoming, env);
    const json = await res.json();

    expect(json.choices[0].message).toEqual({
      role: "assistant",
      content: "Let me check that.",
      tool_calls: [
        { id: "toolu_1", type: "function", function: { name: "get_weather", arguments: '{"city":"Chicago"}' } },
      ],
    });
    expect(json.choices[0].finish_reason).toBe("tool_calls");
  });

  it("sets gen_ai input/output message attributes, splitting out system instructions", async () => {
    const body = {
      messages: [
        { role: "system", content: "be nice" },
        { role: "user", content: "hi" },
      ],
    };
    const incoming = new URL("https://llms-from-the-top.jessitron.com/v1/chat/completions");
    await routeToAnthropic(body, incoming, env);

    expect(capturedAttributes["gen_ai.operation.name"]).toBe("chat");
    expect(JSON.parse(capturedAttributes["gen_ai.system_instructions"])).toEqual([
      { type: "text", content: "be nice" },
    ]);
    expect(JSON.parse(capturedAttributes["gen_ai.input.messages"])).toEqual([
      { role: "user", parts: [{ type: "text", content: "hi" }] },
    ]);
    expect(JSON.parse(capturedAttributes["gen_ai.output.messages"])).toEqual([
      {
        role: "assistant",
        parts: [{ type: "text", content: "hello there" }],
        finish_reason: "end_turn",
      },
    ]);
  });

  it("translates a tool_use/tool_result exchange into gen_ai parts instead of blank text, and records the raw form", async () => {
    const body = {
      messages: [
        { role: "user", content: "what's the weather in Chicago?" },
        {
          role: "assistant",
          content: null,
          tool_calls: [
            { id: "call_1", type: "function", function: { name: "get_weather", arguments: '{"city":"Chicago"}' } },
          ],
        },
        { role: "tool", tool_call_id: "call_1", content: "72 and sunny" },
      ],
    };
    const incoming = new URL("https://llms-from-the-top.jessitron.com/v1/chat/completions");
    await routeToAnthropic(body, incoming, env);

    const rawInput = JSON.parse(capturedAttributes["app.raw_input_messages"]);
    expect(rawInput).toEqual([
      { role: "user", content: "what's the weather in Chicago?" },
      {
        role: "assistant",
        content: [{ type: "tool_use", id: "call_1", name: "get_weather", input: { city: "Chicago" } }],
      },
      {
        role: "user",
        content: [{ type: "tool_result", tool_use_id: "call_1", content: "72 and sunny" }],
      },
    ]);
    expect(JSON.parse(capturedAttributes["gen_ai.input.messages"])).toEqual([
      { role: "user", parts: [{ type: "text", content: "what's the weather in Chicago?" }] },
      {
        role: "assistant",
        parts: [{ type: "tool_call", id: "call_1", name: "get_weather", arguments: '{"city":"Chicago"}' }],
      },
      { role: "user", parts: [{ type: "tool_call_response", id: "call_1", response: "72 and sunny" }] },
    ]);
  });

  it("includes tool_use blocks in gen_ai.output.messages instead of dropping them, and records the raw form", async () => {
    fetchMock.mockResolvedValue(
      Response.json({
        id: "msg_456",
        model: "claude-haiku-4-5-20251001",
        content: [
          { type: "text", text: "Let me check that." },
          { type: "tool_use", id: "toolu_1", name: "get_weather", input: { city: "Chicago" } },
        ],
        stop_reason: "tool_use",
        usage: { input_tokens: 10, output_tokens: 5 },
      }),
    );
    const body = { messages: [{ role: "user", content: "what's the weather in Chicago?" }] };
    const incoming = new URL("https://llms-from-the-top.jessitron.com/v1/chat/completions");
    await routeToAnthropic(body, incoming, env);

    expect(JSON.parse(capturedAttributes["app.raw_output_message"])).toEqual([
      { type: "text", text: "Let me check that." },
      { type: "tool_use", id: "toolu_1", name: "get_weather", input: { city: "Chicago" } },
    ]);
    expect(JSON.parse(capturedAttributes["gen_ai.output.messages"])).toEqual([
      {
        role: "assistant",
        parts: [
          { type: "text", content: "Let me check that." },
          { type: "tool_call", id: "toolu_1", name: "get_weather", arguments: '{"city":"Chicago"}' },
        ],
        finish_reason: "tool_calls",
      },
    ]);
  });
});
