# Detailed Setup Guide

This guide walks through setting up the GPU Inference Stack from scratch.

## Prerequisites

### System Requirements

- **OS**: Ubuntu 20.04+ (or similar Linux distribution)
- **GPU**: NVIDIA GPU with 8GB+ VRAM
- **RAM**: 16GB+ system RAM recommended
- **Storage**: 100GB+ free space for models
- **Network**: Internet access for pulling images and models

### Software Requirements

1. **Docker**
2. **Docker Compose**
3. **NVIDIA Drivers**
4. **NVIDIA Container Toolkit**

## Step 1: Install NVIDIA Drivers

Check if drivers are installed:
```bash
nvidia-smi
```

If not installed:
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install nvidia-driver-535  # or latest

# Reboot
sudo reboot
```

## Step 2: Install Docker

```bash
# Remove old versions
sudo apt remove docker docker-engine docker.io containerd runc

# Install dependencies
sudo apt update
sudo apt install ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Set up repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Add your user to docker group
sudo usermod -aG docker $USER
newgrp docker
```

Verify:
```bash
docker --version
docker compose version
```

## Step 3: Install NVIDIA Container Toolkit

```bash
# Configure repository
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Install
sudo apt update
sudo apt install -y nvidia-container-toolkit

# Configure Docker
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify GPU access in Docker:
```bash
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

## Step 4: Clone and Configure

```bash
# Clone repository
cd ~
git clone <your-repo-url> gpu-inference-stack
cd gpu-inference-stack

# Choose and copy server profile. Pick the one matching this box:
#   servers/server-default.env        8-24GB, vLLM, small models
#   servers/server-high-vram.env      48GB+, vLLM
#   servers/server-multi-gpu.env      2+ GPUs, tensor parallel
#   servers/server-a6000-48gb.env     A6000 48GB, llama.cpp, contract box
#   servers/server-blackwell-97gb.env RTX PRO 6000 97GB, llama.cpp, deep/vision
cp servers/server-high-vram.env .env

# Generate secure keys
openssl rand -hex 32  # Use for LITELLM_MASTER_KEY
openssl rand -base64 32  # Use for GRAFANA_ADMIN_PASSWORD

# Edit configuration
nano .env
```

### Critical Settings to Configure

1. **Server Identification**:
```bash
SERVER_NAME=gpu-prod-01
SERVER_PROFILE=high-vram
```

2. **GPU Configuration**:
```bash
GPU_DEVICES=0  # or "0,1" for multi-GPU
```

3. **Security**:
```bash
LITELLM_MASTER_KEY=<your-generated-key>
GRAFANA_ADMIN_PASSWORD=<your-secure-password>
```

4. **Models**:
```bash
VLLM_MODEL=Qwen/Qwen2.5-7B-Instruct
OLLAMA_PRELOAD_MODELS="qwen2.5:7b gemma3:12b"
```

5. **Bind address** — check this before deploying:
```bash
ss -lntp | grep ':8080'   # anything already here?
```
LiteLLM binds `0.0.0.0:8080` by default, and `0.0.0.0` covers loopback — so a
service holding even `127.0.0.1:8080` blocks it. Pin the interface if so:
```bash
LITELLM_BIND_ADDR=<this box's LAN or Netbird address>
```
The `server-a6000-48gb.env` profile already sets this, because that box runs
another service on 8080.

### If this box uses llama.cpp instead of vLLM

The two engines are mutually exclusive per GPU and `deploy.sh` exits non-zero
if both are enabled. The llama.cpp profiles ship with **both** disabled, so
enable exactly one:

```bash
ENABLE_VLLM=false
ENABLE_LLAMACPP=true
```

llama.cpp needs its GGUF weights on disk **before** the first deploy — nothing
downloads them for you, and they are 35-82 GB:

```bash
mkdir -p ./data/llamacpp/models
# Via container — needs no host Python. On Ubuntu the system Python is
# PEP 668 externally-managed AND lacks ensurepip, so neither `pip install`
# nor `python3 -m venv` works without `apt install python3.12-venv`.
docker run --rm -v "$PWD/data/llamacpp/models:/out" \
  --entrypoint sh python:3.12-slim -c \
  'pip install -q "huggingface_hub[cli]" && \
   hf download unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF \
     Qwen3-Next-80B-A3B-Instruct-UD-Q3_K_XL.gguf --local-dir /out'
```

Verify the runtime image carries kernels for this box's compute capability —
a mismatch does not degrade, every request dies with "no kernel image is
available for execution on the device":

```bash
docker run --rm --entrypoint sh $LLAMACPP_IMAGE -c '/app/llama-server --version'
```

Full guide, including quant selection and five failure modes:
[LLAMACPP.md](LLAMACPP.md).

## Step 5: Deploy

```bash
# Make scripts executable
chmod +x scripts/*.sh

# Deploy
./scripts/deploy.sh
```

This will:
1. Validate prerequisites
2. Create data directories
3. Pull Docker images
4. Start all services
5. Show access URLs

## Step 6: Verify Installation

```bash
# Run health check
./scripts/health-check.sh

# Check specific services
curl http://localhost:8080/health  # LiteLLM
curl http://localhost:9090/-/healthy  # Prometheus
curl http://localhost:3000/api/health  # Grafana
```

## Step 7: Initial Configuration

### 1. Access Grafana

1. Open http://localhost:3000
2. Login with admin / <your-password>
3. Navigate to Dashboards → GPU Overview
4. Verify metrics are displaying

### 2. Test LiteLLM

```bash
export LITELLM_KEY=<your-master-key>

# List models
curl http://localhost:8080/v1/models \
  -H "Authorization: Bearer $LITELLM_KEY"

# Test inference
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -d '{
    "model": "qwen2.5-7b-vllm",
    "messages": [{"role": "user", "content": "Say hello!"}],
    "max_tokens": 50
  }'
```

### 3. Load Ollama Models

```bash
# Pull additional models
docker exec ollama ollama pull llama3.1:8b
docker exec ollama ollama pull codellama:13b

# List loaded models
docker exec ollama ollama list
```

## Step 8: Enable Auto-Start (Optional)

To make services start on boot:

```bash
# Add to crontab
crontab -e

# Add this line:
@reboot cd /home/<user>/gpu-inference-stack && ./scripts/deploy.sh
```

Or create a systemd service:

```bash
sudo nano /etc/systemd/system/gpu-inference-stack.service
```

```ini
[Unit]
Description=GPU Inference Stack
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/<user>/gpu-inference-stack
ExecStart=/home/<user>/gpu-inference-stack/scripts/deploy.sh
ExecStop=/usr/bin/docker compose down
User=<user>
Group=<user>

[Install]
WantedBy=multi-user.target
```

Enable:
```bash
sudo systemctl daemon-reload
sudo systemctl enable gpu-inference-stack
sudo systemctl start gpu-inference-stack
```

## Advanced Configuration

### Custom Model Locations

To use existing model files:

```bash
# In .env
OLLAMA_MODELS_DIR=/mnt/models/ollama
VLLM_CACHE_DIR=/mnt/models/vllm
HF_HOME=/mnt/models/huggingface
```

### Network Configuration

To expose services externally, edit `.env`:

```bash
# Bind to all interfaces
OLLAMA_HOST=0.0.0.0
LITELLM_PORT=0.0.0.0:8080
```

**Warning**: Use firewall and authentication for external access!

### Resource Limits

Fine-tune GPU memory:

```bash
# For 48GB GPU with multiple services
VLLM_GPU_MEMORY_UTILIZATION=0.60  # 28.8GB for vLLM
OLLAMA_MAX_LOADED_MODELS=2        # Rest for Ollama
ENABLE_EMBEDDINGS=true            # ~2GB
```

### Multiple vLLM Instances

To run multiple vLLM containers with different models, use `docker-compose.override.yml`:

```yaml
version: '3.8'
services:
  vllm-large:
    extends: vllm
    container_name: vllm-large
    ports:
      - "8001:8000"
    environment:
      - VLLM_MODEL=meta-llama/Llama-3.1-70B-Instruct
    deploy:
      resources:
        reservations:
          devices:
            - device_ids: ['1']  # Different GPU
```

## Troubleshooting

### Permission Denied

```bash
# Add user to docker group
sudo usermod -aG docker $USER
newgrp docker
```

### Port Already in Use

```bash
# Find process
sudo lsof -i :<port>

# Change port in .env
LITELLM_PORT=8081
```

### GPU Not Detected

```bash
# Check NVIDIA runtime
docker info | grep -i runtime

# Reinstall toolkit
sudo apt install --reinstall nvidia-container-toolkit
sudo systemctl restart docker
```

### Out of Memory

1. Check GPU usage: `nvidia-smi`
2. Reduce `VLLM_GPU_MEMORY_UTILIZATION`
3. Disable services: `ENABLE_EMBEDDINGS=false`
4. Use smaller models

### Models Won't Download

```bash
# Check disk space
df -h

# Check HuggingFace access
docker exec vllm curl https://huggingface.co

# Use HF_TOKEN for gated models
# In .env: HF_TOKEN=hf_xxxxx
```

## Next Steps

1. Review [README.md](../README.md) for usage examples
2. Customize `config/litellm/config.yaml` for your models
3. Set up monitoring alerts
4. Configure backups: `./scripts/backup-config.sh`
5. Test failover and recovery procedures

## Getting Help

- Check logs: `docker compose logs -f`
- Run diagnostics: `./scripts/health-check.sh`
- GPU monitoring: `watch -n 1 nvidia-smi`
- Container stats: `docker stats`
