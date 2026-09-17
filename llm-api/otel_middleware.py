"""
Manual OTel instrumentation for the parts vLLM's own tracing doesn't cover:
an HTTP span (so we know who called and how), and the prompt/completion
text (vLLM's built-in tracer only ever records latency/token-count metrics,
never content).

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
"""

import json
import os

from opentelemetry import propagate
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import SpanKind, Status, StatusCode

MAX_ATTR_LEN = 4000

_provider = TracerProvider(
    resource=Resource.create(
        {"service.name": os.environ.get("OTEL_SERVICE_NAME", "llms-from-the-top-api")}
    )
)
_provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(
            endpoint=os.environ["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"],
            headers={"x-honeycomb-team": os.environ["HONEYCOMB_API_KEY"]},
        )
    )
)
_tracer = _provider.get_tracer("llm-api.http")


def _truncate(value) -> str:
    text = str(value)
    return text if len(text) <= MAX_ATTR_LEN else text[:MAX_ATTR_LEN] + "...(truncated)"


def _record_request_content(span, payload: dict) -> None:
    if "model" in payload:
        span.set_attribute("gen_ai.request.model", payload["model"])
    if "prompt" in payload:
        span.set_attribute("gen_ai.prompt.0.content", _truncate(payload["prompt"]))
    for i, message in enumerate(payload.get("messages", [])):
        span.set_attribute(f"gen_ai.prompt.{i}.role", message.get("role", ""))
        span.set_attribute(f"gen_ai.prompt.{i}.content", _truncate(message.get("content", "")))


def _record_response_content(span, payload: dict) -> None:
    for i, choice in enumerate(payload.get("choices", [])):
        text = choice.get("text")
        if text is None and "message" in choice:
            text = choice["message"].get("content")
        if text is not None:
            span.set_attribute(f"gen_ai.completion.{i}.content", _truncate(text))
        if "finish_reason" in choice:
            span.set_attribute(f"gen_ai.completion.{i}.finish_reason", choice["finish_reason"])
    for key, value in payload.get("usage", {}).items():
        span.set_attribute(f"gen_ai.usage.{key}", value)


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
        if request.client:
            span.set_attribute("client.address", request.client.host)
        if user_agent := request.headers.get("user-agent"):
            span.set_attribute("user_agent.original", user_agent)

        if body:
            try:
                payload = json.loads(body)
            except ValueError:
                payload = None
            if isinstance(payload, dict):
                if not payload.get("model"):
                    # vLLM requires "model" on every request; default to the base
                    # completion model so the workshop examples can omit it.
                    payload["model"] = "base"
                    body = json.dumps(payload).encode("utf-8")
                    request._body = body
                _record_request_content(span, payload)

        _inject_traceparent(request)

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
