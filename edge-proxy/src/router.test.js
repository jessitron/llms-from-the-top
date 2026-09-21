import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
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

  it("returns a 504 when the backend times out", async () => {
    fetchMock.mockRejectedValue(new DOMException("Aborted", "TimeoutError"));
    const res = await routeToBackend(request("/v1/models", { method: "GET" }), env);
    expect(res.status).toBe(504);
    expect(await res.text()).toMatch(/cold-starting/);
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
});
