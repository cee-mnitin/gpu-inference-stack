# Existing GPU Inference Services on crimson-llm2

**Last Updated**: 2026-09-07

This document maps all existing GPU inference services running on the server and how they integrate with the new LiteLLM unified gateway.

---

## 🔍 Discovery Summary

### What Was Found

1. **vLLM Infrastructure** (Docker-based)
   - vLLM container serving Qwen3.6-35B model
   - Nginx router providing model-aware routing

2. **Ollama Service** (Docker container)
   - Multiple models available (Qwen2.5, Gemma3, Granite, etc.)

3. **Embeddings Services** (Native + Docker)
   - 6x text-embeddings-router instances
   - Serving BAAI/bge-m3 and reranker models

4. **PaddleOCR** (Docker container)
   - Vision model with vLLM backend

---

## 📦 Docker Containers

### vllm-qwen36
```bash
Container ID: c40d36b4d387
Image: vllm/vllm-openai:v0.23.0
Status: Up 4 weeks (healthy)
Ports: 0.0.0.0:11502->8000/tcp
Model: Qwen/Qwen3.6-35B-A3B-FP8
```

**Configuration**:
```bash
vllm serve \
  --model Qwen/Qwen3.6-35B-A3B-FP8 \
  --served-model-name qwen3.6 \
  --gpu-memory-utilization 0.65 \
  --max-model-len 16384 \
  --max-num-seqs 62 \
  --no-enable-prefix-caching \
  --enable-expert-parallel \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_xml \
  --reasoning-parser qwen3
```

**Features**:
- ✅ Chat completions
- ✅ Function calling (auto tool choice)
- ✅ Structured output (tool parsers)
- ✅ Reasoning mode
- ✅ Expert parallel (MoE optimization)
- ❌ Prefix caching (disabled)

**Access**:
- Direct: http://localhost:11502/v1
- Via Router: http://localhost:11500/v1 (model: "qwen3.6")
- Via LiteLLM: http://localhost:8080/v1 (models: "qwen3.6-vllm-router", "qwen3.6-vllm-direct")

**GPU Usage**: ~63GB VRAM (65% of 97GB)

---

### vllm-router
```bash
Container ID: ebd9dfc812a2
Image: nginx:1.27-alpine
Status: Up 4 weeks (healthy)
Ports: 0.0.0.0:11500->8080/tcp
```

**Purpose**: Model-aware OpenAI-compatible reverse proxy

**Routing Strategy**:
- Parses JSON request body
- Routes based on "model" field in request
- Routes "qwen3.6" → vllm-qwen36:8000
- Synthesizes /v1/models endpoint (no backend fan-out)

**Configuration**: `/etc/nginx/nginx.conf` with NJS module for body parsing

**Benefits**:
- Single endpoint for multiple backends (extensible)
- Cheaper /v1/models response (no backend queries)
- Health checks at router level
- Request buffering and streaming support

---

### ollama
```bash
Container ID: eb67490a6cf9
Status: Up 2 months (healthy)
Ports: 0.0.0.0:11437->11434/tcp
```

**Available Models**:
```
qwen2.5:7b      (4.7GB) - Q4_K_M quantization
qwen2.5:3b      (1.9GB) - Q4_K_M quantization
qwen3.6:latest  (23.9GB) - 36B MoE, Q4_K_M
gemma3:12b      (8.1GB) - Q4_K_M quantization
granite3.3:8b   (4.9GB) - Q4_K_M quantization
mistral-nemo    (7.1GB) - Q4_0 quantization
llama3.1:8b     (4.9GB) - Q4_K_M quantization
llama3.2:3b     (2.0GB) - Q4_K_M quantization
deepseek-r1:32b (19.9GB) - Q4_K_M quantization
... and more (20 models total)
```

**Access**:
- Direct: http://localhost:11437/api
- Via LiteLLM: http://localhost:8080/v1 (see model names below)

**Features**:
- ✅ Chat completions
- ✅ Structured output (format parameter)
- ✅ Function calling (supported models)
- ✅ Fast loading (GGUF format)
- ✅ Multiple models loaded simultaneously

**Configuration**:
- OLLAMA_NUM_PARALLEL=4
- OLLAMA_MAX_LOADED_MODELS=2
- OLLAMA_FLASH_ATTENTION=1

---

### Embeddings Services

**Port 8082** (Docker container):
```bash
Docker proxy: 172.19.0.19:8080 → 0.0.0.0:8082
```

**Native Services** (6 instances):
```bash
PID 1713354: bge-reranker-v2-m3 (port 8080, 14.7GB RAM)
PID 1713369: bge-m3 (port 8080, 14.6GB RAM)
PID 1817394: bge-reranker-v2-m3 (port 8080, 11.3GB RAM)
... (3 more instances)
```

**Configuration**:
```bash
text-embeddings-router \
  --model-id BAAI/bge-m3 \
  --port 8080 \
  --max-client-batch-size 32 \
  --max-batch-tokens 16384 \
  --max-concurrent-requests 512
```

**Note**: Multiple instances running on same port (likely load-balanced externally)

---

### PaddleOCR (Vision)
```bash
Container: cruxint-backend-ocr_vl_server-1
Status: Up 6 weeks (healthy)
Port: 8118
Model: PaddleOCR-VL-1.6-0.9B
Backend: vLLM
```

---

## 🌐 LiteLLM Integration

### Configured Models

#### vLLM Models (Existing Infrastructure)
```yaml
qwen3.6-vllm-router:
  api_base: http://host.docker.internal:11500/v1
  model: openai/qwen3.6
  features: chat, function_calling, parallel_function_calling

qwen3.6-vllm-direct:
  api_base: http://host.docker.internal:11502/v1
  model: openai/qwen3.6
  features: chat, function_calling, parallel_function_calling
```

#### Ollama Models (Existing Container)
```yaml
qwen2.5-7b-ollama-native:
  api_base: http://host.docker.internal:11437
  model: ollama/qwen2.5:7b

qwen3.6-ollama-native:
  api_base: http://host.docker.internal:11437
  model: ollama/qwen3.6:latest

gemma3-12b-ollama-native:
  api_base: http://host.docker.internal:11437
  model: ollama/gemma3:12b

granite3.3-8b-ollama-native:
  api_base: http://host.docker.internal:11437
  model: ollama/granite3.3:8b
```

#### Embeddings
```yaml
bge-m3-native:
  api_base: http://host.docker.internal:8082
  model: huggingface/BAAI/bge-m3
```

---

## 📊 GPU Resource Allocation

**Total VRAM**: 97GB (RTX PRO 6000 Blackwell)

**Current Usage**:
```
vLLM (Qwen3.6-35B):      ~63GB  (65%)
Ollama (loaded models):  ~15GB  (multiple models)
Embeddings:              ~7GB   (6 instances)
Available:               ~12GB  (buffer)
```

**Note**: Stack is configured to NOT start additional Docker GPU services to avoid OOM

---

## ✅ Tested Features

### Chat Completions
- ✅ vLLM via router: `qwen3.6-vllm-router`
- ✅ vLLM direct: `qwen3.6-vllm-direct`
- ✅ Ollama: `qwen2.5-7b-ollama-native`

### Structured Output
- ✅ vLLM: Tool parsers configured (qwen3_xml)
- ✅ Ollama: Format parameter supported

### Function Calling
- ✅ vLLM: Auto tool choice enabled
- ✅ Ollama: Supported on compatible models

### Reasoning Mode
- ✅ vLLM: Reasoning parser (qwen3) enabled

---

## 🔧 Management

### Start/Stop Services

**LiteLLM Stack** (monitoring + gateway):
```bash
cd /home/crimson/projects/gpu-inference-stack
./scripts/deploy.sh    # Start
./scripts/stop.sh      # Stop
```

**Existing vLLM/Ollama** (Docker Compose):
```bash
# Check status
docker ps | grep -E "vllm|ollama"

# View logs
docker logs vllm-qwen36
docker logs vllm-router
docker logs ollama

# Restart
docker restart vllm-qwen36
docker restart ollama
```

### Health Checks

```bash
# vLLM Router
curl http://localhost:11500/health

# vLLM Direct
curl http://localhost:11502/health

# Ollama
curl http://localhost:11437/api/tags

# LiteLLM (all models)
export KEY=sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20
curl http://localhost:8080/v1/models -H "Authorization: Bearer $KEY"
```

---

## 🚀 Usage Examples

### Via LiteLLM (Unified Gateway)

```bash
export KEY=sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20

# Large model via vLLM
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "model": "qwen3.6-vllm-router",
    "messages": [{"role": "user", "content": "Explain quantum computing"}],
    "max_tokens": 500
  }'

# Small model via Ollama
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "model": "qwen2.5-7b-ollama-native",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }'

# Structured JSON output
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "model": "qwen3.6-vllm-router",
    "messages": [{"role": "user", "content": "List 3 colors"}],
    "response_format": {"type": "json_object"},
    "max_tokens": 100
  }'

# Function calling
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
        "description": "Get current weather",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {"type": "string"}
          },
          "required": ["location"]
        }
      }
    }],
    "tool_choice": "auto"
  }'
```

### Direct Access

**vLLM via Router** (recommended):
```bash
curl -X POST http://localhost:11500/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

**Ollama Native API**:
```bash
curl -X POST http://localhost:11437/api/chat \
  -d '{
    "model": "qwen2.5:7b",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": false
  }'
```

---

## 📈 Monitoring

**Grafana Dashboard**: http://localhost:3001
- GPU metrics (via DCGM Exporter)
- Request latency, throughput
- Cache hit rates
- Memory usage

**Prometheus**: http://localhost:9093
- Raw metrics endpoint

**LiteLLM UI**: http://localhost:8080/ui
- Request logs
- Model status
- Cost tracking

---

## 🎯 Recommendations

### Performance Optimization

1. **Enable Prefix Caching in vLLM**
   ```bash
   # Edit vllm-qwen36 container startup
   # Remove: --no-enable-prefix-caching
   # Add: --enable-prefix-caching
   ```
   **Benefit**: 2-10x speedup for repeated prompts

2. **Increase Max Sequences** (if latency is low)
   ```bash
   # Current: --max-num-seqs 62
   # Try: --max-num-seqs 128
   ```
   **Benefit**: Higher throughput for concurrent requests

3. **Enable Chunked Prefill**
   ```bash
   # Add: --enable-chunked-prefill
   ```
   **Benefit**: Lower TTFT (time to first token)

4. **Use Router for All Access**
   - Router provides better observability
   - Easier to add load balancing later
   - Consistent model naming

### Robustness

1. **Add Health Checks to docker-compose**
   - Currently external containers have health checks
   - Could integrate monitoring

2. **Configure Model Fallbacks in LiteLLM**
   ```yaml
   # Add fallback: qwen2.5-7b when qwen3.6 fails
   ```

3. **Set Up Alerts in Prometheus**
   - GPU memory > 90%
   - Request errors > threshold
   - Service downtime

### Cost Optimization

1. **Unload Unused Ollama Models**
   ```bash
   # Keep only frequently used models loaded
   # Others loaded on-demand
   ```

2. **Reduce Embeddings Instances**
   - 6 instances seems high
   - Monitor actual load and reduce if needed

---

## 🔍 Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     GPU Server (crimson-llm2)                │
│                         97GB VRAM                            │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              LiteLLM Unified Gateway                  │  │
│  │                 Port 8080                             │  │
│  │  ┌─────────────────────────────────────────────┐    │  │
│  │  │ - Model routing & fallbacks                  │    │  │
│  │  │ - Caching (Redis)                            │    │  │
│  │  │ - Cost tracking                              │    │  │
│  │  │ - Observability (Prometheus/Grafana)         │    │  │
│  │  └─────────────────────────────────────────────┘    │  │
│  └──────────────────────────────────────────────────────┘  │
│                          │                                   │
│        ┌─────────────────┼─────────────────┐               │
│        │                 │                 │                │
│        ▼                 ▼                 ▼                │
│  ┌──────────┐    ┌──────────┐     ┌──────────────┐        │
│  │  vLLM    │    │  Ollama  │     │  Embeddings  │        │
│  │  Router  │    │ Container│     │   (Native)   │        │
│  │  :11500  │    │  :11437  │     │    :8082     │        │
│  └────┬─────┘    └──────────┘     └──────────────┘        │
│       │                                                     │
│       ▼                                                     │
│  ┌──────────┐                                              │
│  │  vLLM    │                                              │
│  │ Qwen3.6  │                                              │
│  │  :11502  │                                              │
│  │  (63GB)  │                                              │
│  └──────────┘                                              │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 📝 Notes

1. **Port 8000 Mystery Solved**: What appeared to be a "native" vLLM process on port 8000 was actually the vLLM process INSIDE the vllm-qwen36 Docker container (PID 3920512, container ID c40d36b4d387). The containerd-shim parent process confirmed this.

2. **No Additional GPU Services**: The new stack (gpu-inference-stack) is configured to use existing services only. Docker GPU services (ENABLE_OLLAMA=false, ENABLE_VLLM=false) are disabled to avoid GPU memory conflicts.

3. **Model Naming**: LiteLLM model names include suffixes like "-native", "-router", "-direct" to distinguish access methods while the underlying service models use simpler names.

4. **Host Access**: Docker containers use `host.docker.internal` to access services on the host (existing containers). This is configured via `docker-compose.override.yml`.

---

**Last Verified**: 2026-09-07 09:17 UTC
