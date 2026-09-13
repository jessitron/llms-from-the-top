"""
Serves Qwen2.5-0.5B — a true base model, not instruction-tuned — behind
vLLM's OpenAI-compatible server, deployed on Modal.

Because it's a base model, hit /v1/completions (raw text-in, text-out).
There is no chat template, so /v1/chat/completions won't behave usefully here.

Deploy:   modal deploy app.py
Dev/test: modal serve app.py   (spins up a temporary URL, tears down on Ctrl-C)
"""

import modal

MODEL_NAME = "Qwen/Qwen2.5-0.5B"
SERVED_MODEL_NAME = "base"

vllm_image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install(
        "vllm==0.6.6.post1",
        "huggingface_hub[hf_transfer]==0.26.2",
    )
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1"})
)

app = modal.App("llms-from-the-top-base")

hf_cache_vol = modal.Volume.from_name("llms-from-the-top-hf-cache", create_if_missing=True)
vllm_cache_vol = modal.Volume.from_name("llms-from-the-top-vllm-cache", create_if_missing=True)


@app.function(
    image=vllm_image,
    gpu="T4",
    scaledown_window=15 * 60,
    timeout=10 * 60,
    volumes={
        "/root/.cache/huggingface": hf_cache_vol,
        "/root/.cache/vllm": vllm_cache_vol,
    },
)
@modal.concurrent(max_inputs=32)
@modal.web_server(port=8000, startup_timeout=10 * 60)
def serve():
    import subprocess

    cmd = [
        "vllm", "serve",
        MODEL_NAME,
        "--served-model-name", SERVED_MODEL_NAME,
        "--host", "0.0.0.0",
        "--port", "8000",
        # T4 has compute capability 7.5; bfloat16 (vLLM's default) needs 8.0+.
        "--dtype", "half",
    ]
    subprocess.Popen(" ".join(cmd), shell=True)
