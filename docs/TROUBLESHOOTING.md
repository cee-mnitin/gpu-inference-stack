# Troubleshooting Guide

Common issues and solutions for the GPU Inference Stack.

## Table of Contents

- [Deployment Issues](#deployment-issues)
- [GPU Problems](#gpu-problems)
- [Performance Issues](#performance-issues)
- [Model Loading Problems](#model-loading-problems)
- [Networking Issues](#networking-issues)
- [Monitoring Issues](#monitoring-issues)

## Deployment Issues

### Docker Compose Fails to Start

**Symptoms**: Services won't start, containers crash immediately

**Diagnosis**:
```bash
docker compose logs
docker compose ps
```

**Solutions**:

1. **Missing .env file**:
```bash
cp .env.example .env
# Edit .env
./scripts/deploy.sh
```

2. **Invalid configuration**:
```bash
# Validate YAML syntax
docker compose config
```

3. **Port conflicts**:
```bash
# Find conflicting process
sudo lsof -i :8080

# Change port in .env
LITELLM_PORT=8081
```

4. **Permission errors**:
```bash
# Fix data directory permissions
sudo chown -R $USER:$USER ./data
chmod -R 755 ./data
```

### NVIDIA Runtime Not Found

**Symptoms**: `could not select device driver "nvidia"`

**Solution**:
```bash
# Install NVIDIA Container Toolkit
sudo apt install nvidia-container-toolkit

# Configure Docker
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

## GPU Problems

### GPU Not Detected in Container

**Diagnosis**:
```bash
# Check host GPU
nvidia-smi

# Check Docker runtime
docker info | grep -i runtime

# Try manual GPU access
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

**Solutions**:

1. **Reinstall NVIDIA toolkit**:
```bash
sudo apt remove --purge nvidia-container-toolkit
sudo apt autoremove
sudo apt install nvidia-container-toolkit
sudo systemctl restart docker
```

2. **Check GPU device IDs**:
```bash
# List GPUs
nvidia-smi -L

# Update .env with correct IDs
GPU_DEVICES=0  # or "0,1" for multi-GPU
```

### Out of GPU Memory

**Symptoms**: `CUDA out of memory`, container crashes

**Diagnosis**:
```bash
nvidia-smi
docker stats
```

**Solutions**:

1. **Reduce vLLM memory usage**:
```bash
# In .env
VLLM_GPU_MEMORY_UTILIZATION=0.50  # Reduce from 0.65
VLLM_MAX_MODEL_LEN=8192          # Reduce from 16384
VLLM_MAX_NUM_SEQS=32             # Reduce from 64
```

2. **Disable services**:
```bash
ENABLE_EMBEDDINGS=false
ENABLE_OLLAMA=false  # If using vLLM only
```

3. **Use smaller models**:
```bash
VLLM_MODEL=Qwen/Qwen2.5-7B-Instruct  # Instead of 35B
```

4. **Clear GPU memory**:
```bash
docker compose down
sudo fuser -k /dev/nvidia*
./scripts/deploy.sh
```

### GPU Temperature Too High

**Symptoms**: GPU throttling, reduced performance

**Diagnosis**:
```bash
nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader -l 1
```

**Solutions**:

1. **Check cooling**:
   - Verify fans are working
   - Clean dust from heatsinks
   - Improve case airflow

2. **Reduce load**:
```bash
# Limit concurrent requests
VLLM_MAX_NUM_SEQS=32
OLLAMA_NUM_PARALLEL=2
```

3. **Set temperature limits** (if supported):
```bash
sudo nvidia-smi -pl 250  # Limit power to 250W
```

## Performance Issues

### High Latency

**Diagnosis**:
```bash
# Test inference speed
time curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -d '{"model": "qwen2.5-7b-vllm", "messages": [{"role": "user", "content": "test"}]}'

# Check GPU utilization
nvidia-smi dmon -s mu
```

**Solutions**:

1. **Enable prefix caching** (vLLM):
```bash
VLLM_ENABLE_PREFIX_CACHING=true
VLLM_ENABLE_CHUNKED_PREFILL=true
```

2. **Increase cache size**:
```bash
REDIS_MAXMEMORY=4gb
```

3. **Optimize batch size**:
```bash
# vLLM
VLLM_MAX_NUM_SEQS=64  # Increase for throughput
VLLM_MAX_BATCH_SIZE=128

# Ollama
OLLAMA_NUM_PARALLEL=4
```

4. **Check for CPU bottlenecks**:
```bash
docker stats
htop
```

### Low GPU Utilization

**Diagnosis**:
```bash
nvidia-smi dmon
watch -n 1 nvidia-smi
```

**Solutions**:

1. **Increase concurrent requests**:
```bash
VLLM_MAX_NUM_SEQS=128
```

2. **Enable continuous batching**:
```bash
VLLM_ENABLE_CHUNKED_PREFILL=true
```

3. **Use tensor parallelism** (multi-GPU):
```bash
VLLM_TENSOR_PARALLEL_SIZE=2
GPU_DEVICES=0,1
```

### Memory Leaks

**Symptoms**: Gradual memory increase, eventual crash

**Diagnosis**:
```bash
docker stats --no-stream
nvidia-smi --query-gpu=memory.used --format=csv -l 10
```

**Solutions**:

1. **Restart services regularly**:
```bash
# Add to crontab for daily restart
0 4 * * * cd /path/to/gpu-inference-stack && docker compose restart vllm ollama
```

2. **Check for zombie processes**:
```bash
docker compose exec vllm ps aux | grep Z
```

3. **Clear caches**:
```bash
docker exec redis redis-cli FLUSHALL
docker compose restart litellm
```

## Model Loading Problems

### Model Won't Download

**Symptoms**: Stuck at "Downloading model", timeouts

**Diagnosis**:
```bash
docker compose logs vllm
docker compose exec vllm df -h
docker compose exec vllm curl https://huggingface.co
```

**Solutions**:

1. **Check disk space**:
```bash
df -h
# Clean up if needed
docker system prune -a
```

2. **Use HuggingFace token** (for gated models):
```bash
# Get token from https://huggingface.co/settings/tokens
# In .env:
HF_TOKEN=hf_xxxxxxxxxxxxx
```

3. **Manual download**:
```bash
docker compose exec vllm bash
huggingface-cli download Qwen/Qwen2.5-7B-Instruct
```

4. **Use local model path**:
```bash
# Download model to host
# Mount in docker-compose.yml:
volumes:
  - /path/to/models:/models
# In .env:
VLLM_MODEL=/models/Qwen2.5-7B-Instruct
```

### Ollama Model Not Found

**Symptoms**: "model not found" error

**Solutions**:

1. **Pull model manually**:
```bash
docker exec ollama ollama pull qwen2.5:7b
docker exec ollama ollama list
```

2. **Check model name**:
```bash
# Exact name required
curl http://localhost:11434/api/tags
```

3. **Wait for preload**:
```bash
# Models specified in OLLAMA_PRELOAD_MODELS take time to load
docker compose logs ollama | grep -i "pulling"
```

### Model Incompatibility

**Symptoms**: "unsupported model", crashes during loading

**Solutions**:

1. **Check vLLM supported models**:
   - Visit: https://docs.vllm.ai/en/latest/models/supported_models.html

2. **Use correct quantization**:
```bash
# Some quantizations require specific flags
VLLM_EXTRA_ARGS="--quantization awq"
```

3. **Check GPU compatibility**:
```bash
# Some models require specific compute capability
nvidia-smi --query-gpu=compute_cap --format=csv
```

## Networking Issues

### Can't Connect to Services

**Diagnosis**:
```bash
docker compose ps
netstat -tlnp | grep -E "8080|9090|3000"
curl -v http://localhost:8080/health
```

**Solutions**:

1. **Check if service is running**:
```bash
docker compose ps
docker compose logs litellm
```

2. **Verify ports**:
```bash
# In .env, ensure ports are correct
LITELLM_PORT=8080
GRAFANA_PORT=3000
```

3. **Check firewall**:
```bash
sudo ufw status
sudo ufw allow 8080/tcp
```

4. **Test from inside container**:
```bash
docker compose exec litellm curl http://localhost:4000/health
```

### CORS Errors

**Symptoms**: Browser blocks requests from different origin

**Solution**:

Add to `docker-compose.override.yml`:
```yaml
services:
  litellm:
    environment:
      - LITELLM_CORS_ALLOWED_ORIGINS=http://localhost:3000,https://yourdomain.com
```

### SSL/TLS Issues

**Setup HTTPS with Let's Encrypt**:

1. Enable nginx profile
2. Get SSL certificate:
```bash
docker compose run --rm certbot certonly --webroot \
  -w /var/www/certbot \
  -d yourdomain.com \
  --email you@email.com
```

3. Update nginx config with SSL paths
4. Restart nginx

## Monitoring Issues

### No Metrics in Grafana

**Diagnosis**:
```bash
# Check Prometheus targets
curl http://localhost:9090/api/v1/targets

# Check datasource in Grafana
curl -u admin:admin http://localhost:3000/api/datasources
```

**Solutions**:

1. **Verify Prometheus is scraping**:
```bash
curl http://localhost:9090/api/v1/query?query=up
```

2. **Check network connectivity**:
```bash
docker compose exec grafana ping prometheus
docker compose exec prometheus ping dcgm-exporter
```

3. **Restart services**:
```bash
docker compose restart prometheus grafana
```

### GPU Metrics Missing

**Diagnosis**:
```bash
docker compose logs dcgm-exporter
curl http://localhost:9400/metrics
```

**Solutions**:

1. **Check DCGM exporter**:
```bash
docker compose restart dcgm-exporter
docker compose logs dcgm-exporter
```

2. **Verify GPU access**:
```bash
docker compose exec dcgm-exporter nvidia-smi
```

3. **Check Prometheus config**:
```bash
cat config/prometheus/prometheus.yml | grep dcgm
```

## Emergency Procedures

### Complete Reset

```bash
# Stop everything
docker compose down -v

# Remove all data (WARNING: deletes everything)
rm -rf data/*

# Start fresh
./scripts/deploy.sh
```

### Recover from Crash

```bash
# Check what's running
docker ps -a

# Check logs for crashed containers
docker logs <container-id>

# Remove crashed containers
docker compose down
docker compose up -d

# Verify
./scripts/health-check.sh
```

### Backup Before Troubleshooting

```bash
# Backup current state
./scripts/backup-config.sh

# Also backup data if needed
tar -czf data-backup-$(date +%Y%m%d).tar.gz data/
```

## Getting More Help

1. **Check logs**:
```bash
docker compose logs -f --tail=100
```

2. **Run diagnostics**:
```bash
./scripts/health-check.sh
nvidia-smi
docker stats
```

3. **Collect debug info**:
```bash
# Create debug report
cat > debug-report.txt <<EOF
=== System Info ===
$(uname -a)
$(nvidia-smi)

=== Docker Info ===
$(docker --version)
$(docker compose version)
$(docker info | grep -i runtime)

=== Service Status ===
$(docker compose ps)

=== Recent Logs ===
$(docker compose logs --tail=50)

=== Environment ===
$(cat .env | grep -v KEY | grep -v PASSWORD)
EOF
```

4. **Contact support** with debug report
