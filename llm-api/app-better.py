"""
Serves a third, modern Mistral model behind vLLM's OpenAI-compatible server,
as its own Modal app — separate from app.py's base/chat pair.

app.py's two functions are a matched pair (same weights, base vs.
instruction-tuned) meant to be deployed/stopped together for that
comparison. This model is a different demo point (what a modern,
better-tuned model looks like) on a different, pricier GPU, so it gets its
own app: deploying/stopping it doesn't touch the base/chat pair.

Deploy:   modal deploy app-better.py
Dev/test: modal serve app-better.py   (spins up a temporary URL, tears down on Ctrl-C)
"""

import os

import modal

MODEL_NAME = "mistralai/Mistral-Small-3.2-24B-Instruct-2506"
SERVED_MODEL_NAME = "better"
HONEYCOMB_TRACES_ENDPOINT = "https://api.honeycomb.io/v1/traces"
OTEL_SERVICE_NAME = "llms-from-the-top-api"

vllm_image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install(
        # 0.6.6 predates support for this model's architecture
        # (Mistral3ForConditionalGeneration, added in 0.8.3). Avoid 0.8.4,
        # which regressed Mistral Small 3.1 inference.
        "vllm==0.8.5",
        # left unpinned, pip picks a transformers new enough to rename
        # PixtralRotaryEmbedding, which breaks vllm 0.8.5's own import of it.
        "transformers==4.53.0",
        "huggingface_hub[hf_transfer]>=0.30.0",
        # vLLM's own OTel tracing (--otlp-traces-endpoint) is an optional
        # import — these packages aren't in vllm's own requirements.
        # pinned to 1.26.0, not 1.27.0: vllm 0.8.5 requires opentelemetry-sdk
        # <1.27.0.
        "opentelemetry-sdk==1.26.0",
        "opentelemetry-exporter-otlp-proto-http==1.26.0",
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
)

app = modal.App("llms-from-the-top-better")

# Same cache volumes as app.py's — it's just a HF/vLLM download cache, safe
# to share across apps, and saves a redundant download if a model ever
# overlaps.
hf_cache_vol = modal.Volume.from_name("llms-from-the-top-hf-cache", create_if_missing=True)
vllm_cache_vol = modal.Volume.from_name("llms-from-the-top-vllm-cache", create_if_missing=True)

honeycomb_secret = modal.Secret.from_name("honeycomb", required_keys=["HONEYCOMB_API_KEY"])


@app.function(
    image=vllm_image,
    # 24B weights in bf16 are ~48GB by themselves — an L40S's 48GB has no
    # room left for vLLM's KV cache once they're loaded, so this needs an
    # 80GB card.
    gpu="A100-80GB",
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
def serve_better():
    import subprocess

    cmd = [
        "vllm", "serve",
        MODEL_NAME,
        "--served-model-name", SERVED_MODEL_NAME,
        "--host", "0.0.0.0",
        "--port", "8000",
        "--max-model-len", "4096",
        # This repo is mistral-native (params.json/tekken.json, no
        # preprocessor_config.json), so all three mistral-format flags are
        # needed together, per vLLM's own Mistral-Small serving guide.
        "--tokenizer-mode", "mistral",
        "--config-format", "mistral",
        "--load-format", "mistral",
        # text-only demo — no image input needed. Single-quoted because cmd
        # is run through a shell below, which would otherwise eat the
        # double quotes this JSON needs.
        "--limit-mm-per-prompt", "'{\"image\":0}'",
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
        "GEN_AI_RESPONSE_MODEL": MODEL_NAME,
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
