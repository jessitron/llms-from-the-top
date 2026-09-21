"""
Serves two Mistral 7B models behind vLLM's OpenAI-compatible server, each its
own Modal function (so its own URL): a true base model and its
instruction-tuned sibling, deployed on Modal.

The base model isn't instruction-tuned, so hit /v1/completions on it (raw
text-in, text-out) — there's no chat template, so /v1/chat/completions won't
behave usefully there. The chat model understands /v1/chat/completions.

Deploy:   modal deploy app.py
Dev/test: modal serve app.py   (spins up temporary URLs, tears down on Ctrl-C)
"""

import os

import modal

MODEL_NAME = "mistralai/Mistral-7B-v0.1"
SERVED_MODEL_NAME = "base"
CHAT_MODEL_NAME = "mistralai/Mistral-7B-Instruct-v0.1"
CHAT_SERVED_MODEL_NAME = "chat"
HONEYCOMB_TRACES_ENDPOINT = "https://api.honeycomb.io/v1/traces"
HONEYCOMB_LOGS_ENDPOINT = "https://api.honeycomb.io/v1/logs"
OTEL_SERVICE_NAME = "llms-from-the-top-api"

vllm_image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install(
        "vllm==0.6.6.post1",
        "huggingface_hub[hf_transfer]==0.26.2",
        # vLLM's own OTel tracing (--otlp-traces-endpoint) is an optional
        # import — these packages aren't in vllm's own requirements.
        "opentelemetry-sdk==1.27.0",
        "opentelemetry-exporter-otlp-proto-http==1.27.0",
        "opentelemetry-semantic-conventions-ai==0.4.2",
        # otel_middleware.py uses this to call vLLM's own /tokenize and
        # /detokenize endpoints to capture the chat-template-rendered prompt.
        "httpx==0.27.2",
    )
    .env({
        "HF_HUB_ENABLE_HF_TRANSFER": "1",
        # so `--middleware otel_middleware.trace_http_requests` can import it
        "PYTHONPATH": "/root",
    })
    .add_local_file(
        local_path=os.path.join(os.path.dirname(__file__), "otel_middleware.py"),
        remote_path="/root/otel_middleware.py",
    )
    # Tells vLLM (via VLLM_LOGGING_CONFIG_PATH below) to route its own log
    # records through otel_middleware.build_otel_log_handler in addition to
    # stdout, so they show up in Honeycomb next to the traces.
    .add_local_file(
        local_path=os.path.join(os.path.dirname(__file__), "vllm_logging_config.json"),
        remote_path="/root/vllm_logging_config.json",
    )
)

app = modal.App("llms-from-the-top-base")

hf_cache_vol = modal.Volume.from_name("llms-from-the-top-hf-cache", create_if_missing=True)
vllm_cache_vol = modal.Volume.from_name("llms-from-the-top-vllm-cache", create_if_missing=True)

# One-time setup: modal secret create honeycomb HONEYCOMB_API_KEY=<your Honeycomb API key>
honeycomb_secret = modal.Secret.from_name("honeycomb", required_keys=["HONEYCOMB_API_KEY"])


def _serve_vllm(model_name, served_model_name):
    import os
    import subprocess

    cmd = [
        "vllm", "serve",
        model_name,
        "--served-model-name", served_model_name,
        "--host", "0.0.0.0",
        "--port", "8000",
        # Model's default max_model_len (32768) needs more KV cache than an
        # A10G has room for once the 7B weights are loaded, so vLLM refuses
        # to start. Workshop requests are a few hundred tokens; this leaves
        # plenty of cache for concurrent requests too.
        "--max-model-len", "2048",
        # Otherwise vLLM logs periodic throughput stats (via
        # vllm.engine.metrics) every ~10s, which vllm_logging_config.json
        # routes to Honeycomb as noisy, low-value log events.
        "--disable-log-stats",
        "--otlp-traces-endpoint", HONEYCOMB_TRACES_ENDPOINT,
        # Adds the root HTTP span (client info, prompt/completion content)
        # that vLLM's own --otlp-traces-endpoint tracer doesn't record.
        "--middleware", "otel_middleware.trace_http_requests",
    ]

    env = {
        **os.environ,
        # otel_middleware.py reads this to populate gen_ai.response.model,
        # since vLLM's own response body only ever echoes served_model_name
        # (our alias), never the real HF model id.
        "GEN_AI_RESPONSE_MODEL": model_name,
        "OTEL_SERVICE_NAME": OTEL_SERVICE_NAME,
        # vLLM defaults the OTLP protocol to grpc; Honeycomb's traces
        # endpoint above is the http/protobuf one.
        "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/protobuf",
        "OTEL_EXPORTER_OTLP_HEADERS": f"x-honeycomb-team={os.environ['HONEYCOMB_API_KEY']}",
        # otel_middleware.py builds its own exporter from this directly,
        # since it runs a separate TracerProvider from vLLM's own tracer.
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": HONEYCOMB_TRACES_ENDPOINT,
        # Makes vLLM's own log records (it logs via stdlib `logging`, not
        # print) flow through otel_middleware.build_otel_log_handler, which
        # reads this endpoint directly.
        "VLLM_LOGGING_CONFIG_PATH": "/root/vllm_logging_config.json",
        "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": HONEYCOMB_LOGS_ENDPOINT,
    }
    subprocess.Popen(" ".join(cmd), shell=True, env=env)


@app.function(
    image=vllm_image,
    # 7B weights in fp16/bf16 are ~14GB — doesn't fit in a T4's 16GB
    # alongside vLLM's KV cache, so this model needs the bigger card.
    gpu="A10G",
    scaledown_window=30 * 60,
    timeout=10 * 60,
    volumes={
        "/root/.cache/huggingface": hf_cache_vol,
        "/root/.cache/vllm": vllm_cache_vol,
    },
    secrets=[honeycomb_secret],
)
@modal.concurrent(max_inputs=32)
@modal.web_server(port=8000, startup_timeout=10 * 60)
def serve():
    _serve_vllm(MODEL_NAME, SERVED_MODEL_NAME)


@app.function(
    image=vllm_image,
    gpu="A10G",
    scaledown_window=30 * 60,
    timeout=10 * 60,
    volumes={
        "/root/.cache/huggingface": hf_cache_vol,
        "/root/.cache/vllm": vllm_cache_vol,
    },
    secrets=[honeycomb_secret],
)
@modal.concurrent(max_inputs=32)
@modal.web_server(port=8000, startup_timeout=10 * 60)
def serve_chat():
    _serve_vllm(CHAT_MODEL_NAME, CHAT_SERVED_MODEL_NAME)
