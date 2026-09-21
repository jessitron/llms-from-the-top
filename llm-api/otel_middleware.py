"""
Manual OTel instrumentation for the parts vLLM's own tracing doesn't cover:
an HTTP span (so we know who called and how), the prompt/completion text
(vLLM's built-in tracer only ever records latency/token-count metrics,
never content), and — for /v1/chat/completions — the prompt as rendered by
the model's chat template, via a round-trip through vLLM's own /tokenize
and /detokenize endpoints (run concurrently with the real request, so it
doesn't add latency).

Wired in via vLLM's `--middleware otel_middleware.trace_http_requests` flag
(see app.py) — no vLLM source changes needed.

Buffers the full response body to read the completion text back out, so it
doesn't support `stream: true` requests (the response would need to be
forwarded chunk-by-chunk instead).

We extract the incoming `traceparent` header (set by edge-proxy, the
Cloudflare Worker in front of this API) as the parent context, so this span
joins that caller's trace instead of starting a new one. We then inject a
fresh `traceparent` for the request we're about to route onward, so that
vLLM's own engine span (which extracts trace context from incoming request
headers) nests under the span this middleware creates, even though the two
use separate TracerProviders. If there's no incoming header — a direct call
to the Modal URL, bypassing edge-proxy — `propagate.extract` on an empty
carrier just yields an empty context, so this span becomes the trace root,
same as before.

gen_ai.conversation.id rides along as OTel Baggage (the W3C `baggage`
header) rather than a plain header — edge-proxy sets it there.
`propagate.extract` picks up baggage the same way it picks up traceparent
(OTel's default global propagator handles both), and BaggageSpanProcessor
below copies every baggage entry onto every span this provider creates —
not just the root HTTP span — mirroring the BaggageSpanProcessor edge-proxy
runs on its own TracerProvider.
"""

import asyncio
import json
import os

import httpx
from opentelemetry import baggage, propagate
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import SpanProcessor, TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import SpanKind, Status, StatusCode

MAX_ATTR_LEN = 4000

OPERATION_NAMES = {
    "/v1/chat/completions": "chat",
    "/v1/completions": "text_completion",
}


class BaggageSpanProcessor(SpanProcessor):
    def on_start(self, span, parent_context=None):
        for key, value in baggage.get_all(parent_context).items():
            span.set_attribute(key, value)


_provider = TracerProvider(
    resource=Resource.create(
        {"service.name": os.environ.get("OTEL_SERVICE_NAME", "llms-from-the-top-api")}
    )
)
_provider.add_span_processor(BaggageSpanProcessor())
_provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(
            endpoint=os.environ["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"],
            headers={"x-honeycomb-team": os.environ["HONEYCOMB_API_KEY"]},
        )
    )
)
_tracer = _provider.get_tracer("llm-api.http")


def build_otel_log_handler():
    """Factory referenced by vllm_logging_config.json (via VLLM_LOGGING_CONFIG_PATH)
    so vLLM's own `logging`-module log records — which is how vLLM logs, there's
    no print() involved — get exported to Honeycomb alongside the traces above.
    Shares the same Resource (service.name) as the trace provider so logs land
    in the same dataset.
    """
    from opentelemetry._logs import set_logger_provider
    from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor

    logger_provider = LoggerProvider(resource=_provider.resource)
    logger_provider.add_log_record_processor(
        BatchLogRecordProcessor(
            OTLPLogExporter(
                endpoint=os.environ["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"],
                headers={"x-honeycomb-team": os.environ["HONEYCOMB_API_KEY"]},
            )
        )
    )
    set_logger_provider(logger_provider)
    return LoggingHandler(logger_provider=logger_provider)


def _truncate(value) -> str:
    text = str(value)
    return text if len(text) <= MAX_ATTR_LEN else text[:MAX_ATTR_LEN] + "...(truncated)"


def _genai_message(role: str, content) -> dict:
    # Honeycomb's Gen AI message format (see edge-proxy/genai-message-format.md):
    # each message becomes {role, parts: [{type: "text", content}]} — note the
    # part field is `content`, not `text`. Mirrors the same shape edge-proxy
    # sends for gen_ai.input.messages / gen_ai.output.messages.
    return {"role": role, "parts": [{"type": "text", "content": _truncate(content) if content is not None else ""}]}


def _record_request_content(span, payload: dict) -> None:
    if "model" in payload:
        span.set_attribute("gen_ai.request.model", payload["model"])
    if "prompt" in payload:
        span.set_attribute("gen_ai.input.messages", json.dumps([_genai_message("user", payload["prompt"])]))
    messages = payload.get("messages")
    if messages:
        span.set_attribute(
            "gen_ai.input.messages",
            json.dumps([_genai_message(m.get("role", ""), m.get("content")) for m in messages]),
        )


def _record_response_content(span, payload: dict) -> None:
    output_messages = []
    for choice in payload.get("choices", []):
        text = choice.get("text")
        role = "assistant"
        if text is None and "message" in choice:
            text = choice["message"].get("content")
            role = choice["message"].get("role", "assistant")
        message = _genai_message(role, text)
        if "finish_reason" in choice:
            message["finish_reason"] = choice["finish_reason"]
        output_messages.append(message)
    if output_messages:
        span.set_attribute("gen_ai.output.messages", json.dumps(output_messages))
    for key, value in payload.get("usage", {}).items():
        span.set_attribute(f"gen_ai.usage.{key}", value)


async def _fetch_rendered_prompt(payload: dict) -> str | None:
    """For /v1/chat/completions requests, ask vLLM's own /tokenize and
    /detokenize endpoints to apply the model's chat template and tokenizer,
    then decode back to text — reconstructing the exact prompt string the
    model actually sees, not just the raw `messages` we were sent.
    """
    messages = payload.get("messages")
    if not messages:
        return None
    try:
        async with httpx.AsyncClient(base_url="http://localhost:8000", timeout=5.0) as client:
            tokenize_resp = await client.post(
                "/tokenize",
                json={
                    "model": payload.get("model"),
                    "messages": messages,
                    "add_generation_prompt": True,
                },
            )
            tokenize_resp.raise_for_status()
            tokens = tokenize_resp.json()["tokens"]

            detokenize_resp = await client.post(
                "/detokenize",
                json={"model": payload.get("model"), "tokens": tokens},
            )
            detokenize_resp.raise_for_status()
            return detokenize_resp.json()["prompt"]
    except Exception:
        return None


def _inject_traceparent(request) -> None:
    injected: dict = {}
    propagate.inject(injected)
    headers = [
        (k, v)
        for k, v in request.scope.get("headers", [])
        if k.decode("latin-1").lower() not in ("traceparent", "tracestate")
    ]
    headers.extend((k.encode("latin-1"), v.encode("latin-1")) for k, v in injected.items())
    request.scope["headers"] = headers


async def trace_http_requests(request, call_next):
    from starlette.responses import Response as StarletteResponse

    body = await request.body()

    incoming_context = propagate.extract(
        {k.decode("latin-1"): v.decode("latin-1") for k, v in request.scope.get("headers", [])}
    )

    with _tracer.start_as_current_span(
        f"{request.method} {request.url.path}",
        context=incoming_context,
        kind=SpanKind.SERVER,
    ) as span:
        span.set_attribute("http.request.method", request.method)
        span.set_attribute("url.path", request.url.path)
        if operation_name := OPERATION_NAMES.get(request.url.path):
            span.set_attribute("gen_ai.operation.name", operation_name)
        # vLLM's own request/response "model" field is just our
        # --served-model-name alias (e.g. "chat"), same as what the caller
        # sent — it never surfaces the real HF model id. app.py/app-better.py
        # set this env var to the real name at deploy time.
        if real_model_name := os.environ.get("GEN_AI_RESPONSE_MODEL"):
            span.set_attribute("gen_ai.response.model", real_model_name)
        span.set_attribute("modal.task_id", os.environ.get("MODAL_TASK_ID", ""))
        if request.client:
            span.set_attribute("client.address", request.client.host)
        if user_agent := request.headers.get("user-agent"):
            span.set_attribute("user_agent.original", user_agent)

        payload = None
        if body:
            try:
                payload = json.loads(body)
            except ValueError:
                payload = None
            if isinstance(payload, dict):
                _record_request_content(span, payload)

        _inject_traceparent(request)

        # Path check matters: this middleware also wraps our own /tokenize
        # calls below, whose request body also contains "messages" — without
        # it, each chat request recursively re-triggers itself via /tokenize.
        if (
            request.url.path == "/v1/chat/completions"
            and isinstance(payload, dict)
            and "messages" in payload
        ):
            rendered_prompt, response = await asyncio.gather(
                _fetch_rendered_prompt(payload), call_next(request)
            )
            if rendered_prompt:
                span.set_attribute("gen_ai.prompt.rendered", _truncate(rendered_prompt))
        else:
            response = await call_next(request)
        span.set_attribute("http.response.status_code", response.status_code)
        if response.status_code >= 400:
            span.set_status(Status(StatusCode.ERROR))

        response_body = b"".join(
            [chunk async for chunk in response.body_iterator]  # type: ignore[union-attr]
        )
        try:
            resp_payload = json.loads(response_body)
        except ValueError:
            resp_payload = None
        if isinstance(resp_payload, dict):
            _record_response_content(span, resp_payload)

        return StarletteResponse(
            content=response_body,
            status_code=response.status_code,
            headers=dict(response.headers),
            media_type=response.media_type,
        )
