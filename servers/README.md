# Server Profiles

This directory contains preconfigured server profiles for different GPU configurations.

## Available Profiles

### 1. Default Profile (`server-default.env`)

**For**: Entry-level GPU servers
- Single GPU with 8-24GB VRAM
- Examples: RTX 3090, RTX 4090, A10

**Configuration**:
- Ollama with small models (7B)
- vLLM with 7B model
- 50% GPU memory utilization
- No embeddings service
- 2 parallel requests

**Use when**: You have a consumer-grade GPU or limited VRAM

### 2. High VRAM Profile (`server-high-vram.env`)

**For**: Professional/datacenter single GPU servers
- Single GPU with 48GB+ VRAM
- Examples: RTX 6000 Ada, A100, H100, L40S

**Configuration**:
- Ollama with multiple large models
- vLLM with 35B model
- 65% GPU memory utilization
- Embeddings service enabled
- 4 parallel requests
- Prefix caching enabled
- Tool calling enabled

**Use when**: You have a high-end workstation or datacenter GPU

### 3. Multi-GPU Profile (`server-multi-gpu.env`)

**For**: Multi-GPU servers
- 2+ GPUs
- Examples: 2x A100, 4x H100, etc.

**Configuration**:
- Tensor parallelism enabled (models split across GPUs)
- vLLM using both GPUs
- 70% GPU memory utilization
- Multiple Ollama models
- Embeddings service on separate GPU
- 4 parallel requests
- Enhanced throughput settings

**Use when**: You have multiple GPUs and want to run large models

### 4. A6000 48GB Profile (`server-a6000-48gb.env`)

- **Hardware**: RTX A6000, `sm_86` (Ampere), 48 GB VRAM, 251 GB RAM
- **Storage**: rotational SAS, **no NVMe** — hence `LLAMACPP_LAZY_MODE=off`
- **Engine**: llama.cpp (vLLM cannot use FP8/NVFP4 natively on `sm_86`)
- **Model**: Qwen3-Next-80B-A3B `UD-Q3_K_XL`, 33.19 GiB, 4 slots x 32k
- **Contract**: fills `interactive` + `bulk` + `fast`; `vision` unserved
- **Note**: sets `LITELLM_BIND_ADDR` — required, port 8080 is occupied there

### 5. Blackwell 97GB Profile (`server-blackwell-97gb.env`)

- **Hardware**: RTX PRO 6000 Blackwell Max-Q, `sm_120`, 97 GB VRAM
- **Engine**: llama.cpp, image pinned to `b10644` (llama.cpp#28355)
- **Model**: Qwen3.8-Flash-Next `UD-IQ3_XXS`, 76.3 GiB, 1 slot x 128k
- **Contract**: fills `interactive` + `vision`; `bulk`/`fast` point at the A6000
- **Verify first**: confirm the image carries `sm_120` kernels, or every
  request dies with "no kernel image is available for execution on the device"

**Both of these ship with both engines disabled.** Enable exactly one —
`deploy.sh` exits non-zero if `ENABLE_VLLM` and `ENABLE_LLAMACPP` are both
true. See [../docs/LLAMACPP.md](../docs/LLAMACPP.md).

## How to Use

### Quick Start

1. Copy the appropriate profile:
```bash
cp servers/server-high-vram.env .env
```

2. Edit for your specific needs:
```bash
nano .env
```

3. Deploy:
```bash
./scripts/deploy.sh
```

### Customizing a Profile

All profiles are starting points. Customize based on:

1. **Your GPU**: Check VRAM with `nvidia-smi`
2. **Your models**: Adjust which models to load
3. **Your workload**: Tune concurrent requests

## Creating Custom Profiles

Create server-specific profiles for your fleet:

```bash
# Create profile
cp servers/server-default.env servers/prod-gpu-01.env

# Edit with server-specific settings
nano servers/prod-gpu-01.env

# Commit to git
git add servers/prod-gpu-01.env
git commit -m "Add prod-gpu-01 profile"
```

On the server:
```bash
ln -s servers/prod-gpu-01.env .env
./scripts/deploy.sh
```

## Profile Comparison

| Feature | Default | High VRAM | Multi-GPU | A6000 48GB | Blackwell 97GB |
|---------|---------|-----------|-----------|------------|----------------|
| VRAM Required | 8-24GB | 48GB+ | 96GB+ total | 48GB | 97GB |
| Chat engine | vLLM | vLLM | vLLM | llama.cpp | llama.cpp |
| Ollama Models | 1 small | 3-4 mixed | 4+ mixed | none | none |
| Chat model size | 7B | 35B | 35B+ | 80B-A3B | 125B-A6B |
| GPU Memory % | 50% | 65% | 70% | fit-managed | fit-managed |
| Embeddings | No | Yes | Yes | Yes (Infinity) | Yes (Infinity) |
| Parallel Requests | 2 | 4 | 4 | 4 | 1 |
| Context per slot | 8k | 16k | 32k | 32k | 128k |
| Tensor Parallel | No | No | Yes | No | No |
| Prefix Caching | No | Yes | Yes | Yes (cache-reuse) | Yes (cache-reuse) |
| Contract chat roles | all 3 | all 3 | all 3 | all 3 | interactive only |
| `gpu/chat/vision` | Ollama | Ollama | Ollama | unserved | the model itself |

## Key Variables Explained

### GPU Configuration
```bash
GPU_DEVICES=0          # Which GPU to use (0,1 for multi-GPU)
GPU_VRAM_TOTAL=96      # Total VRAM in GB (for documentation)
```

### Ollama Settings
```bash
ENABLE_OLLAMA=true                    # Enable/disable Ollama
OLLAMA_NUM_PARALLEL=4                 # Concurrent requests
OLLAMA_MAX_LOADED_MODELS=2            # Max models in memory
OLLAMA_PRELOAD_MODELS="model1 model2" # Auto-load these models
```

### vLLM Settings
```bash
VLLM_MODEL=Qwen/Qwen2.5-7B-Instruct         # HuggingFace model
VLLM_MODEL_NAME=qwen2.5-7b                  # Name in LiteLLM
VLLM_GPU_MEMORY_UTILIZATION=0.65            # % of GPU to use
VLLM_MAX_MODEL_LEN=16384                    # Max context length
VLLM_MAX_NUM_SEQS=64                        # Batch size
VLLM_TENSOR_PARALLEL_SIZE=1                 # GPUs for model
VLLM_ENABLE_PREFIX_CACHING=true             # Cache repeated prefixes
```

### Embeddings Settings
```bash
ENABLE_EMBEDDINGS=true                      # Enable/disable
EMBEDDINGS_MODEL=BAAI/bge-m3                # Model to use
EMBEDDINGS_MAX_BATCH_TOKENS=16384           # Batch size
```

## GPU Memory Guidelines

### How to Calculate

Total VRAM needed ≈ Model Size + Context Buffer + Overhead

**Example for 48GB GPU**:
- vLLM 35B model (FP8): ~18GB
- Context buffer (16K): ~8GB
- Ollama 7B models (2x): ~8GB
- Embeddings: ~2GB
- Overhead: ~4GB
- **Total**: ~40GB (83% of 48GB) ✓

### Optimization Tips

1. **Too little VRAM?**
   - Reduce `VLLM_GPU_MEMORY_UTILIZATION`
   - Use smaller models
   - Reduce `VLLM_MAX_MODEL_LEN`
   - Disable embeddings

2. **VRAM to spare?**
   - Increase `VLLM_MAX_NUM_SEQS` for throughput
   - Load more Ollama models
   - Increase `VLLM_MAX_MODEL_LEN`

3. **Multiple GPUs?**
   - Use tensor parallelism for large models
   - Or run different models on different GPUs
   - Dedicate one GPU to embeddings

## Troubleshooting Profiles

### Profile doesn't work

```bash
# Check GPU
nvidia-smi

# Check actual VRAM
nvidia-smi --query-gpu=memory.total --format=csv,noheader

# Test with reduced settings
VLLM_GPU_MEMORY_UTILIZATION=0.40
VLLM_MAX_MODEL_LEN=8192
```

### Want to test before deploying?

```bash
# Dry run
docker compose config

# Check memory would fit
# (Model size in GB) / (GPU VRAM in GB) < GPU_MEMORY_UTILIZATION
```

## Examples

### Example 1: RTX 4090 (24GB)
```bash
cp servers/server-default.env .env
# Edit:
GPU_VRAM_TOTAL=24
VLLM_MODEL=Qwen/Qwen2.5-14B-Instruct
VLLM_GPU_MEMORY_UTILIZATION=0.60
ENABLE_EMBEDDINGS=false
```

### Example 2: A100 (80GB)
```bash
cp servers/server-high-vram.env .env
# Edit:
GPU_VRAM_TOTAL=80
VLLM_MODEL=meta-llama/Llama-3.1-70B-Instruct
VLLM_GPU_MEMORY_UTILIZATION=0.70
OLLAMA_MAX_LOADED_MODELS=3
```

### Example 3: 2x H100 (160GB total)
```bash
cp servers/server-multi-gpu.env .env
# Edit:
GPU_DEVICES=0,1
GPU_VRAM_TOTAL=160
VLLM_MODEL=meta-llama/Llama-3.1-405B-Instruct-FP8
VLLM_TENSOR_PARALLEL_SIZE=2
VLLM_GPU_MEMORY_UTILIZATION=0.75
```

## Contributing

Found a profile that works well for a specific GPU? Contribute it!

```bash
# Create your profile
cp .env servers/server-rtx4090.env

# Document it
# Add to this README

# Submit PR
git add servers/server-rtx4090.env servers/README.md
git commit -m "Add RTX 4090 profile"
```
