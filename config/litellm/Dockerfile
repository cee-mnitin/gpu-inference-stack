# Bakes Pillow into the upstream litellm image so the Ollama-backed
# gpu/chat/vision contract alias can actually serve an image.
#
# Without it EVERY vision call through this stack fails with:
#   litellm.APIConnectionError: ollama image conversion failed
#   please run `pip install Pillow`  ->  ModuleNotFoundError: No module named 'PIL'
#
# This is the failure mode health-check.sh warns about and cannot see: the
# alias is present in /v1/models, Ollama is healthy and has the model, so the
# contract probe reports gpu/chat/vision ✓ and a consumer's boot check
# (ember's required_infra) passes — then every real request 500s. LiteLLM
# needs Pillow only for the Ollama path (it base64s images itself for
# OpenAI-compatible backends), so a vLLM-backed vision role would not hit it.
#
# Keep the base tag in sync with docker-compose.yml's litellm image.
FROM ghcr.io/berriai/litellm:main-latest

# Neither pip nor uv is present in the base image's runtime layer — only the
# venv's interpreter. ensurepip bootstraps pip into that same interpreter, so
# Pillow lands where litellm will actually import it from.
RUN python3 -m ensurepip --default-pip \
    && python3 -m pip install --no-cache-dir Pillow
