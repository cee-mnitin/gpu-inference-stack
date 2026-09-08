# Quick Reference Guide - GPU Inference Stack

**Fast access to common commands and endpoints.**

---

## 🚀 Quick Start

```bash
# Deploy stack
cd /home/crimson/projects/gpu-inference-stack
./scripts/deploy.sh

# Check health
./scripts/health-check.sh

# View logs
docker compose logs -f litellm

# Stop stack
./scripts/stop.sh
```

---

## 🌐 Endpoints

| Service | URL | Auth Required |
|---------|-----|---------------|
| **LiteLLM API** | http://localhost:8080/v1 | ✅ Bearer token |
| **LiteLLM UI** | http://localhost:8080/ui | ✅ Bearer token |
| **Grafana** | http://localhost:3001 | ✅ admin/admin123changeme |
| **Prometheus** | http://localhost:9093 | ❌ No |
| **Existing vLLM Router** | http://localhost:11500/v1 | ❌ No |
| **Existing vLLM Direct** | http://localhost:11502/v1 | ❌ No |
| **Existing Ollama** | http://localhost:11437/api | ❌ No |

---

## 🔑 Authentication

```bash
# Set API key
export LITELLM_KEY=sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20

# Or use in requests
curl -H "Authorization: Bearer sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20" \
  http://localhost:8080/v1/models
```

---

## 💬 Chat Completion Examples

### Via LiteLLM (Recommended)

```bash
export KEY=sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20

# Large model (vLLM)
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "model": "qwen3.6-vllm-router",
    "messages": [{"role": "user", "content": "Explain quantum computing"}],
    "max_tokens": 500
  }'

# Small model (Ollama)
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "model": "qwen2.5-7b-ollama-native",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

### Direct to Existing vLLM

```bash
# Via router
curl -X POST http://localhost:11500/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 50
  }'

# Direct
curl -X POST http://localhost:11502/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 50
  }'
```

---

## 📝 Available Models

### Via LiteLLM

```bash
export KEY=sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20
curl http://localhost:8080/v1/models -H "Authorization: Bearer $KEY" | jq -r '.data[].id'
```

**Current Models**:
- `qwen3.6-vllm-router` - Large model via router (recommended)
- `qwen3.6-vllm-direct` - Large model direct access
- `qwen2.5-7b-ollama-native` - Fast 7B model
- `qwen3.6-ollama-native` - 36B MoE model
- `gemma3-12b-ollama-native` - 12B model
- `granite3.3-8b-ollama-native` - 8B model
- `bge-m3-native` - Embeddings

**After vLLM Migration** (future):
- `qwen3.6-new-router` - New enhanced vLLM via router
- `qwen3.6-new-direct` - New enhanced vLLM direct

---

## 🧪 Function Calling

```bash
export KEY=sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20

curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "model": "qwen3.6-vllm-router",
    "messages": [{"role": "user", "content": "What is the weather in Paris?"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {"type": "string", "description": "City name"}
          },
          "required": ["location"]
        }
      }
    }],
    "tool_choice": "auto"
  }'
```

---

## 📊 Monitoring

### Check GPU Usage

```bash
watch -n 1 nvidia-smi
```

### View Service Status

```bash
docker compose ps
```

### Check Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f litellm
docker compose logs -f prometheus

# Existing vLLM
docker logs -f vllm-qwen36
docker logs -f vllm-router
```

### Grafana Dashboards

1. Open http://localhost:3001
2. Login: admin / admin123changeme
3. Go to Dashboards → GPU Overview

### Prometheus Metrics

```bash
# Query examples
curl 'http://localhost:9093/api/v1/query?query=up'
curl 'http://localhost:9093/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL'
```

---

## 🔧 Management Commands

### Start/Stop

```bash
cd /home/crimson/projects/gpu-inference-stack

# Start all services
./scripts/deploy.sh

# Stop all services
./scripts/stop.sh

# Restart specific service
docker compose restart litellm

# Stop existing vLLM (before migration)
docker stop vllm-qwen36 vllm-router

# Start existing vLLM (rollback)
docker start vllm-qwen36 vllm-router
```

### Health Checks

```bash
# Automated check
./scripts/health-check.sh

# Manual checks
curl http://localhost:8080/health
curl http://localhost:11500/health
curl http://localhost:11502/health
curl http://localhost:9093/-/healthy
curl http://localhost:3001/api/health
```

### Updates

```bash
# Update all images
./scripts/update.sh

# Update specific service
docker compose pull litellm
docker compose up -d litellm
```

### Backup

```bash
# Backup configuration
./scripts/backup-config.sh

# Manual backup
tar -czf gpu-stack-backup-$(date +%Y%m%d).tar.gz \
  config/ .env docker-compose.yml docker-compose.override.yml
```

---

## 🐛 Troubleshooting

### Service Won't Start

```bash
# Check logs
docker compose logs <service-name>

# Check config validity
docker compose config

# Restart service
docker compose restart <service-name>
```

### GPU Out of Memory

```bash
# Check GPU usage
nvidia-smi

# Stop Docker GPU services
docker compose down vllm ollama

# Or reduce vLLM memory in .env
VLLM_GPU_MEMORY_UTILIZATION=0.50
```

### Port Already in Use

```bash
# Find what's using a port
sudo lsof -i :8080

# Change port in .env
nano .env
LITELLM_PORT=8081

# Redeploy
./scripts/deploy.sh
```

### Can't Connect to Service

```bash
# Check if service is running
docker compose ps

# Check if port is exposed
docker compose port litellm 4000

# Test from inside container
docker exec litellm curl http://localhost:4000/health

# Check Docker network
docker network inspect gpu-inference-net
```

---

## 🎯 Common Tasks

### Test All Models

```bash
export KEY=sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20

# Get model list
MODELS=$(curl -s http://localhost:8080/v1/models -H "Authorization: Bearer $KEY" | jq -r '.data[].id')

# Test each model
for model in $MODELS; do
  echo "Testing $model..."
  curl -s -X POST http://localhost:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $KEY" \
    -d "{\"model\": \"$model\", \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}], \"max_tokens\": 10}" \
    | jq -r '.choices[0].message.content // .error.message'
  echo
done
```

### Monitor Performance

```bash
# Watch GPU continuously
watch -n 1 'nvidia-smi && echo && docker stats --no-stream'

# Check vLLM throughput
docker logs vllm-qwen36 2>&1 | grep "throughput" | tail -5

# Check LiteLLM cache hit rate
docker logs litellm 2>&1 | grep "cache" | tail -10
```

### Change vLLM Model

```bash
# Edit .env
nano .env
# Change: VLLM_MODEL=Qwen/SomeOtherModel

# Redeploy (will download new model)
ENABLE_VLLM=true ./scripts/deploy.sh
```

---

## 📚 Documentation

| Document | Purpose |
|----------|---------|
| `README.md` | Overview and setup |
| `MIGRATION_GUIDE.md` | Step-by-step vLLM migration |
| `VLLM_COMPARISON.md` | Detailed feature comparison |
| `EXISTING_SERVICES.md` | Current infrastructure docs |
| `QUICKSTART.md` | Fast deployment guide |
| `POST_REVIEW_STATUS.md` | Deployment readiness status |
| `TROUBLESHOOTING.md` | Common issues and fixes |

---

## 🔗 Useful Links

- **LiteLLM Docs**: https://docs.litellm.ai/
- **vLLM Docs**: https://docs.vllm.ai/
- **Ollama Docs**: https://ollama.ai/
- **Prometheus Query**: https://prometheus.io/docs/prometheus/latest/querying/basics/
- **Grafana Dashboards**: https://grafana.com/grafana/dashboards/

---

## 💡 Pro Tips

1. **Always use LiteLLM for access** - Better caching, monitoring, and fallbacks
2. **Watch GPU memory** - Keep under 90% to avoid OOM
3. **Enable prefix caching in vLLM** - 2-10x faster for repeated prompts
4. **Use router over direct access** - Better observability and easier to scale
5. **Monitor Grafana regularly** - Catch issues before they affect users
6. **Backup .env and configs** - Easy rollback if needed
7. **Test in parallel before migration** - Validate new vLLM on different ports first
8. **Use smaller models for simple tasks** - Ollama 7B is much faster than vLLM 35B

---

**Need help?** Check `TROUBLESHOOTING.md` or review logs with `docker compose logs -f`.
