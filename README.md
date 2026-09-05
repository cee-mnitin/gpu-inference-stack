# GPU Inference Stack

A production-ready, modular GPU inference platform for running multiple LLM servers with unified API access, monitoring, and management.

## Features

- **Multiple Inference Backends**: Ollama, vLLM, Text Embeddings
- **Unified API Gateway**: LiteLLM provides a single OpenAI-compatible API for all models
- **Monitoring & Observability**: Prometheus + Grafana with GPU metrics
- **Caching**: Redis-based response caching for improved performance
- **Modular Configuration**: Server profiles for different GPU configurations
- **Production Ready**: Health checks, logging, resource limits
- **Easy Deployment**: Docker Compose with automated scripts

## Architecture

```
┌─────────────────────────────────────────┐
│          LiteLLM Gateway                │
│    (Unified OpenAI-compatible API)      │
└──────────┬──────────────────────────────┘
           │
    ┌──────┴────────┬──────────────┬────────────┐
    │               │              │            │
┌───▼────┐   ┌─────▼─────┐  ┌────▼────┐  ┌────▼────┐
│ Ollama │   │   vLLM    │  │ Embeddings│ │  Redis  │
│ Models │   │  Models   │  │  Service  │ │  Cache  │
└────────┘   └───────────┘  └───────────┘ └─────────┘
     │              │              │
     └──────────────┴──────────────┘
                    │
            ┌───────▼────────┐
            │   GPU (NVIDIA) │
            └────────────────┘

              Monitoring Stack
    ┌──────────────┬─────────────────┐
    │  Prometheus  │     Grafana     │
    │   (Metrics)  │   (Dashboards)  │
    └──────────────┴─────────────────┘
```

## Quick Start

### Prerequisites

- Linux server with NVIDIA GPU(s)
- Docker and Docker Compose
- NVIDIA Container Toolkit (nvidia-docker2)
- At least 16GB VRAM recommended

### Installation

1. Clone this repository:
```bash
git clone <your-repo-url> gpu-inference-stack
cd gpu-inference-stack
```

2. Choose a server profile and create your configuration:
```bash
# For high VRAM GPUs (48GB+)
cp servers/server-high-vram.env .env

# OR for default setup (8-24GB)
cp servers/server-default.env .env

# OR for multi-GPU setups
cp servers/server-multi-gpu.env .env
```

3. Edit `.env` to customize for your server:
```bash
nano .env
```

Key settings to review:
- `SERVER_NAME`: Unique identifier for this server
- `GPU_DEVICES`: Which GPUs to use (e.g., "0" or "0,1")
- `VLLM_MODEL`: Which model to load in vLLM
- `OLLAMA_PRELOAD_MODELS`: Models to preload in Ollama
- `LITELLM_MASTER_KEY`: Generate with `openssl rand -hex 32`
- `GRAFANA_ADMIN_PASSWORD`: Change from default!

4. Deploy the stack:
```bash
./scripts/deploy.sh
```

5. Wait for services to start (2-5 minutes), then verify:
```bash
./scripts/health-check.sh
```

## Usage

### Making Inference Requests

Once deployed, use the unified LiteLLM API (OpenAI-compatible):

```bash
# Chat completion
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{
    "model": "qwen2.5-7b-vllm",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# List available models
curl http://localhost:8080/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

### Available Models

Models are defined in `config/litellm/config.yaml`:

**Ollama Models:**
- `qwen2.5-7b-ollama`
- `qwen3.6-ollama`
- `gemma3-12b-ollama`
- `granite3.3-8b-ollama`

**vLLM Models:**
- `qwen2.5-7b-vllm`
- `qwen3.6-35b-vllm`

**Embeddings:**
- `bge-m3`

### Accessing Web Interfaces

- **LiteLLM UI**: http://localhost:8080/ui
- **Grafana**: http://localhost:3000 (default: admin/admin)
- **Prometheus**: http://localhost:9090

### Management Commands

```bash
# Deploy/start the stack
./scripts/deploy.sh

# Check health of all services
./scripts/health-check.sh

# Update to latest images
./scripts/update.sh

# Stop all services
./scripts/stop.sh

# Backup configuration
./scripts/backup-config.sh

# View logs
docker compose logs -f [service-name]
docker compose logs -f litellm
docker compose logs -f vllm
```

## Server Profiles

### Default Profile (`server-default.env`)
- Single GPU with 8-24GB VRAM
- Ollama with small models
- vLLM with 7B model
- GPU memory: 50%

### High VRAM Profile (`server-high-vram.env`)
- Single GPU with 48GB+ VRAM
- Ollama with multiple large models
- vLLM with 35B model
- Text embeddings enabled
- GPU memory: 65%

### Multi-GPU Profile (`server-multi-gpu.env`)
- 2+ GPUs
- Tensor parallelism enabled in vLLM
- Multiple models across GPUs
- GPU memory: 70%

## Configuration

### Adding New Models

1. **For Ollama**: Pull the model, then add to `.env`:
```bash
docker exec ollama ollama pull llama3.1:70b
# Add to OLLAMA_PRELOAD_MODELS in .env
```

2. **For vLLM**: Update in `.env`:
```bash
VLLM_MODEL=meta-llama/Llama-3.1-70B-Instruct
VLLM_MODEL_NAME=llama3.1-70b
```

3. **Update LiteLLM config** in `config/litellm/config.yaml`

4. Restart services:
```bash
./scripts/update.sh
```

### Customizing Resource Limits

Edit `.env`:
```bash
# vLLM GPU memory
VLLM_GPU_MEMORY_UTILIZATION=0.70

# Ollama parallel requests
OLLAMA_NUM_PARALLEL=4

# Redis cache size
REDIS_MAXMEMORY=4gb
```

## Monitoring

### Grafana Dashboards

Access Grafana at `http://localhost:3000`:

1. **GPU Overview**: Real-time GPU utilization, temperature, memory
2. **LiteLLM Metrics**: Request rates, latency, errors
3. **System Metrics**: CPU, RAM, disk usage

### Prometheus Metrics

Available at `http://localhost:9090`:
- GPU metrics: `DCGM_FI_DEV_*`
- LiteLLM: `litellm_*`
- System: `node_*`

### Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f litellm
docker compose logs -f vllm

# Last 100 lines
docker compose logs --tail=100 ollama
```

## Deploying to Multiple Servers

### Method 1: Git Clone + Custom .env

On each server:
```bash
git clone <repo> gpu-inference-stack
cd gpu-inference-stack
cp servers/server-high-vram.env .env
# Edit .env for this server
./scripts/deploy.sh
```

### Method 2: Centralized Management

1. Create server-specific configs in repo:
```bash
servers/
  ├── prod-server-1.env
  ├── prod-server-2.env
  └── prod-server-3.env
```

2. On each server, symlink the config:
```bash
ln -s servers/prod-server-1.env .env
./scripts/deploy.sh
```

3. Push config changes to git, pull on servers, redeploy

## Troubleshooting

### Services won't start

```bash
# Check logs
docker compose logs

# Verify GPU access
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi

# Check NVIDIA runtime
docker info | grep -i runtime
```

### Out of GPU memory

1. Reduce `VLLM_GPU_MEMORY_UTILIZATION` in `.env`
2. Decrease `VLLM_MAX_MODEL_LEN` or `VLLM_MAX_NUM_SEQS`
3. Disable embeddings: `ENABLE_EMBEDDINGS=false`
4. Use smaller models

### Models not loading

```bash
# Check vLLM logs
docker compose logs vllm

# Check disk space
df -h

# Verify HuggingFace access
docker exec vllm ls -la /root/.cache/huggingface
```

### High latency

1. Enable prefix caching: `VLLM_ENABLE_PREFIX_CACHING=true`
2. Increase cache: `REDIS_MAXMEMORY=4gb`
3. Check GPU utilization in Grafana
4. Review `VLLM_MAX_NUM_SEQS` setting

## Production Recommendations

1. **Change default passwords** in `.env`
2. **Set up SSL/TLS** for external access (see nginx config)
3. **Enable authentication** on Prometheus/Grafana
4. **Regular backups** of `data/` and configs
5. **Monitor disk space** for model caches
6. **Set up alerting** in Prometheus
7. **Use Docker Compose override** for local customizations:
   ```bash
   # docker-compose.override.yml (gitignored)
   version: '3.8'
   services:
     vllm:
       environment:
         - CUSTOM_VAR=value
   ```

## Updating

```bash
# Update images
./scripts/update.sh

# Update configuration
git pull
./scripts/deploy.sh
```

## License

MIT

## Support

For issues and questions:
- Check `docs/` folder for detailed guides
- Review logs: `docker compose logs`
- Run health check: `./scripts/health-check.sh`

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test on a GPU server
4. Submit a pull request
