"""
Serves Qwen2.5-0.5B — a true base model, not instruction-tuned — behind
vLLM's OpenAI-compatible server, deployed on Modal.

Because it's a base model, hit /v1/completions (raw text-in, text-out).
There is no chat template, so /v1/chat/completions won't behave usefully here.

Deploy:   modal deploy app.py
Dev/test: modal serve app.py   (spins up a temporary URL, tears down on Ctrl-C)
"""

import os

import modal

MODEL_NAME = "Qwen/Qwen2.5-0.5B"
SERVED_MODEL_NAME = "base"
HONEYCOMB_TRACES_ENDPOINT = "https://api.honeycomb.io/v1/traces"
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
)

app = modal.App("llms-from-the-top-base")

hf_cache_vol = modal.Volume.from_name("llms-from-the-top-hf-cache", create_if_missing=True)
vllm_cache_vol = modal.Volume.from_name("llms-from-the-top-vllm-cache", create_if_missing=True)

# One-time setup: modal secret create honeycomb HONEYCOMB_API_KEY=<your Honeycomb API key>
honeycomb_secret = modal.Secret.from_name("honeycomb", required_keys=["HONEYCOMB_API_KEY"])


@app.function(
    image=vllm_image,
    gpu="T4",
    scaledown_window=15 * 60,
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
    import os
    import subprocess

    cmd = [
        "vllm", "serve",
        MODEL_NAME,
        "--served-model-name", SERVED_MODEL_NAME,
        "--host", "0.0.0.0",
        "--port", "8000",
        # T4 has compute capability 7.5; bfloat16 (vLLM's default) needs 8.0+.
        "--dtype", "half",
        "--otlp-traces-endpoint", HONEYCOMB_TRACES_ENDPOINT,
        # Adds the root HTTP span (client info, prompt/completion content)
        # that vLLM's own --otlp-traces-endpoint tracer doesn't record.
        "--middleware", "otel_middleware.trace_http_requests",
    ]

    env = {
        **os.environ,
        "OTEL_SERVICE_NAME": OTEL_SERVICE_NAME,
        # vLLM defaults the OTLP protocol to grpc; Honeycomb's traces
        # endpoint above is the http/protobuf one.
        "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/protobuf",
        "OTEL_EXPORTER_OTLP_HEADERS": f"x-honeycomb-team={os.environ['HONEYCOMB_API_KEY']}",
        # otel_middleware.py builds its own exporter from this directly,
        # since it runs a separate TracerProvider from vLLM's own tracer.
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": HONEYCOMB_TRACES_ENDPOINT,
    }
    subprocess.Popen(" ".join(cmd), shell=True, env=env)
