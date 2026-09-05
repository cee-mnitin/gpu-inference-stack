# Quick Start Guide

Get the GPU Inference Stack running in 5 minutes!

## Prerequisites

- Linux with NVIDIA GPU
- Docker + Docker Compose installed
- NVIDIA Container Toolkit installed
- 16GB+ GPU VRAM

## Installation (4 Steps)

### 1. Clone & Navigate

```bash
cd /home/crimson/projects/gpu-inference-stack
```

### 2. Configure

Configuration is already set for crimson-llm2 server. Review:

```bash
cat .env
```

Key settings:
- ✅ Server: crimson-llm2
- ✅ GPU: Device 0 (97GB VRAM)
- ✅ Ports: Configured to avoid conflicts with native services
- ✅ LiteLLM Key: sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20

### 3. Deploy

```bash
./scripts/deploy.sh
```

This will:
- Pull Docker images (~5GB download)
- Start all services
- Takes 2-5 minutes

### 4. Verify

```bash
./scripts/health-check.sh
```

Expected output:
```
✓ LiteLLM
✓ Prometheus
✓ Grafana
✓ Ollama (Docker)
✓ vLLM (Docker)
```

## Usage

### Test Inference

```bash
export LITELLM_KEY=sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20

curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -d '{
    "model": "qwen2.5-7b-ollama-native",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

### List All Models

```bash
curl http://localhost:8080/v1/models \
  -H "Authorization: Bearer $LITELLM_KEY" | jq
```

### Access Web UIs

- **Grafana**: http://localhost:3001 (admin/admin123changeme)
- **LiteLLM UI**: http://localhost:8080/ui
- **Prometheus**: http://localhost:9091

## Common Commands

```bash
# Check status
./scripts/health-check.sh

# View logs
docker compose logs -f

# Stop everything
./scripts/stop.sh

# Restart
./scripts/deploy.sh

# Update images
./scripts/update.sh
```

## Available Models

### Native (Existing Server Services)
- `qwen2.5-7b-ollama-native`
- `qwen3.6-ollama-native` (36B)
- `gemma3-12b-ollama-native`
- `granite3.3-8b-ollama-native`
- `qwen3.6-35b-vllm-native` (35B, fastest)
- `bge-m3-native` (embeddings)

### Docker (New Services)
- `qwen2.5-7b-ollama-docker`
- `gemma3-12b-ollama-docker`
- `qwen2.5-14b-vllm-docker`

## GPU Monitoring

```bash
# Watch GPU usage
watch -n 1 nvidia-smi

# Or use Grafana
# Open http://localhost:3001
# Navigate to "GPU Overview" dashboard
```

## Troubleshooting

### Services won't start
```bash
docker compose logs
```

### GPU out of memory
```bash
# Reduce Docker vLLM memory in .env
VLLM_GPU_MEMORY_UTILIZATION=0.10
./scripts/deploy.sh
```

### Port conflicts
```bash
sudo lsof -i :8080  # Check what's using the port
```

## Next Steps

1. ✅ Stack is deployed
2. 📖 Read full [README.md](README.md)
3. 📖 Review [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md)
4. 🔧 Customize models in `config/litellm/config.yaml`
5. 📊 Set up monitoring alerts
6. 💾 Configure backups

## Python Client Example

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8080/v1",
    api_key="sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20"
)

response = client.chat.completions.create(
    model="qwen3.6-35b-vllm-native",
    messages=[
        {"role": "user", "content": "Write a haiku about GPUs"}
    ]
)

print(response.choices[0].message.content)
```

## Architecture

```
┌──────────────┐
│   Your App   │
└──────┬───────┘
       │
       ▼
┌─────────────────────┐
│  LiteLLM Gateway    │  :8080
│  (Unified API)      │
└──────┬──────────────┘
       │
   ────┴────────────────────────────
   │          │           │         │
   ▼          ▼           ▼         ▼
Native     Native     Docker    Docker
Ollama     vLLM       Ollama    vLLM
:11437     :8000      :11435    :8001
```

## Support

- **Docs**: `docs/` folder
- **Logs**: `docker compose logs -f [service]`
- **Health**: `./scripts/health-check.sh`
- **Troubleshooting**: See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

Happy inferencing! 🚀
