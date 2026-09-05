# Deployment Guide - GPU Inference Stack

## Current Server Configuration (crimson-llm2)

This document describes the deployment on the current server.

### Server Specifications
- **Hostname**: crimson-llm2
- **GPU**: NVIDIA RTX PRO 6000 Blackwell Max-Q (97GB VRAM)
- **Status**: High utilization (93% VRAM used, 100% GPU utilization)

### Existing Services (Native)
These services are already running natively on the host:

1. **Ollama** - Port 11437
   - Models: qwen2.5:7b, qwen3.6:latest, gemma3:12b, granite3.3:8b

2. **vLLM** - Port 8000
   - Model: Qwen/Qwen3.6-35B-A3B-FP8
   - GPU Memory: 65%

3. **Text Embeddings** - Multiple instances on ports 8080+
   - Models: BAAI/bge-m3, bge-reranker-v2-m3

### Docker Stack Configuration (This Repository)
To avoid conflicts, the Docker stack uses different ports:

1. **LiteLLM Gateway** - Port 8080
   - Unified API for all models (native + Docker)

2. **Ollama (Docker)** - Port 11435
   - Additional models capacity

3. **vLLM (Docker)** - Port 8001
   - Running: Qwen/Qwen2.5-14B-Instruct
   - GPU Memory: 20% (shared with native services)

4. **Prometheus** - Port 9091
   - Metrics collection

5. **Grafana** - Port 3001
   - Dashboards and visualization

6. **Redis** - Port 6380
   - Caching for LiteLLM

### Deployment Strategy

**Approach**: Fresh Docker setup alongside existing native services

**Benefits**:
- No downtime to existing services
- Can test Docker stack before migrating
- LiteLLM provides unified API for both native and Docker services
- Easy rollback if issues occur

## Deployment Steps

### 1. Verify Prerequisites

```bash
cd /home/crimson/projects/gpu-inference-stack

# Check existing services
curl http://localhost:11437/api/tags  # Native Ollama
curl http://localhost:8000/health     # Native vLLM

# Check GPU
nvidia-smi

# Check Docker
docker --version
docker compose version
```

### 2. Review Configuration

```bash
# Review .env file
cat .env

# Key settings:
# - SERVER_NAME=crimson-llm2
# - GPU_DEVICES=0
# - VLLM_GPU_MEMORY_UTILIZATION=0.20 (conservative, sharing with native)
# - Ports configured to avoid conflicts
```

### 3. Deploy Stack

```bash
# Deploy all services
./scripts/deploy.sh

# This will:
# 1. Create data directories
# 2. Pull Docker images
# 3. Start services (Ollama, vLLM, LiteLLM, monitoring)
```

### 4. Verify Deployment

```bash
# Run health check
./scripts/health-check.sh

# Check specific services
curl http://localhost:8080/health     # LiteLLM
curl http://localhost:3001/api/health # Grafana
curl http://localhost:9091/-/healthy  # Prometheus

# List available models
curl http://localhost:8080/v1/models \
  -H "Authorization: Bearer sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20"
```

### 5. Test Inference

```bash
export LITELLM_KEY=sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20

# Test native Ollama model via LiteLLM
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -d '{
    "model": "qwen2.5-7b-ollama-native",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# Test Docker vLLM model via LiteLLM
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -d '{
    "model": "qwen2.5-14b-vllm-docker",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# Test native vLLM model via LiteLLM
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -d '{
    "model": "qwen3.6-35b-vllm-native",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### 6. Access Dashboards

- **Grafana**: http://localhost:3001
  - Login: admin / admin123changeme
  - View GPU metrics, service health

- **LiteLLM UI**: http://localhost:8080/ui
  - View request logs, model status

- **Prometheus**: http://localhost:9091
  - View raw metrics

## Available Models via LiteLLM

### From Native Services
- `qwen2.5-7b-ollama-native` - Ollama
- `qwen3.6-ollama-native` - Ollama
- `gemma3-12b-ollama-native` - Ollama
- `granite3.3-8b-ollama-native` - Ollama
- `qwen3.6-35b-vllm-native` - vLLM (35B, high performance)
- `bge-m3-native` - Embeddings

### From Docker Stack
- `qwen2.5-7b-ollama-docker` - Ollama
- `gemma3-12b-ollama-docker` - Ollama
- `qwen2.5-14b-vllm-docker` - vLLM (14B)

## Resource Monitoring

```bash
# Overall system
./scripts/health-check.sh

# GPU usage
watch -n 1 nvidia-smi

# Docker stats
docker stats

# Logs
docker compose logs -f litellm
docker compose logs -f vllm
```

## Management

```bash
# Stop all Docker services (native services unaffected)
./scripts/stop.sh

# Restart a specific service
docker compose restart litellm

# Update images
./scripts/update.sh

# Backup configuration
./scripts/backup-config.sh

# View logs
docker compose logs -f [service-name]
```

## Adjusting GPU Memory

If GPU runs out of memory:

1. **Reduce Docker vLLM memory**:
```bash
# In .env
VLLM_GPU_MEMORY_UTILIZATION=0.15  # Reduce from 0.20
```

2. **Disable Docker services temporarily**:
```bash
# In .env
ENABLE_VLLM=false
ENABLE_OLLAMA=false
# LiteLLM will still proxy to native services
```

3. **Redeploy**:
```bash
./scripts/deploy.sh
```

## Migration Path (Optional)

To eventually migrate from native to Docker:

1. **Phase 1**: Run both (current state)
   - Test Docker stack
   - Verify performance
   - Build confidence

2. **Phase 2**: Migrate services one at a time
   - Stop native Ollama, use Docker Ollama
   - Update LiteLLM config
   - Test thoroughly

3. **Phase 3**: Full Docker deployment
   - Stop all native services
   - Increase Docker resource allocation
   - Decommission native setup

## Troubleshooting

### GPU Out of Memory
```bash
# Check usage
nvidia-smi

# Reduce Docker vLLM memory
# Edit .env: VLLM_GPU_MEMORY_UTILIZATION=0.10
./scripts/deploy.sh
```

### Port Conflicts
```bash
# Find what's using a port
sudo lsof -i :8080

# Change port in .env
LITELLM_PORT=8081
```

### Can't Access Native Services from LiteLLM
```bash
# Check host.docker.internal works
docker compose exec litellm ping host.docker.internal

# Test native service
docker compose exec litellm curl http://host.docker.internal:11437/api/tags
```

## Next Steps

1. ✅ Deploy and verify stack
2. ✅ Test all models through LiteLLM
3. ✅ Monitor GPU and resource usage
4. [ ] Set up automated backups
5. [ ] Configure alerts in Prometheus
6. [ ] Document API usage for applications
7. [ ] Plan migration strategy if desired

## Support

- README: See [README.md](README.md)
- Setup: See [docs/SETUP.md](docs/SETUP.md)
- Issues: See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- Logs: `docker compose logs -f`
