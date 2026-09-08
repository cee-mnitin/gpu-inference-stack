# vLLM Migration Guide - Replacing Existing Infrastructure

**Goal**: Migrate from existing vLLM containers (vllm-qwen36 + vllm-router) to the new managed stack with improvements, while maintaining service continuity.

**Strategy**: Phased migration with rollback capability at each step.

---

## 📋 Pre-Migration Checklist

- [ ] Backup existing vLLM configuration
- [ ] Document current performance metrics
- [ ] Verify LiteLLM stack is running and healthy
- [ ] Confirm all clients use LiteLLM endpoint (http://localhost:8080)
- [ ] Test new vLLM in isolation before migration

---

## 🔄 Migration Phases

### Phase 0: Current State (As-Is)

**Architecture**:
```
Clients
  ↓
[LiteLLM:8080] ─┬→ [vllm-router:11500] → [vllm-qwen36:11502] (EXISTING)
                └→ [ollama:11437] (EXISTING)
```

**Status**:
- ✅ All services accessible via LiteLLM
- ✅ Direct access still available (ports 11500, 11502, 11437)
- ✅ Monitoring via Grafana/Prometheus

**Models in LiteLLM**:
- `qwen3.6-vllm-router` → existing router (11500)
- `qwen3.6-vllm-direct` → existing direct (11502)
- `qwen2.5-7b-ollama-native` → ollama
- `gemma3-12b-ollama-native` → ollama
- etc.

---

### Phase 1: Test New vLLM in Parallel

**Objective**: Validate new vLLM configuration without affecting production.

#### Step 1.1: Enable New vLLM on Different Ports

Edit `.env`:
```bash
# Change ports to avoid conflict with existing
ENABLE_VLLM=true
VLLM_PORT=8001  # Different from existing 11502
VLLM_ROUTER_PORT=8002  # Different from existing 11500
```

**Deploy**:
```bash
cd /home/crimson/projects/gpu-inference-stack
./scripts/deploy.sh
```

**Architecture After**:
```
Clients
  ↓
[LiteLLM:8080] ─┬→ [vllm-router:11500] → [vllm-qwen36:11502] (EXISTING)
                ├→ [vllm-router-new:8002] → [vllm-new:8001] (NEW - testing)
                └→ [ollama:11437]
```

#### Step 1.2: Verify New vLLM

**Test health**:
```bash
# New vLLM direct
curl http://localhost:8001/health

# New router
curl http://localhost:8002/health

# Check models
curl http://localhost:8002/v1/models
```

**Test inference via LiteLLM**:
```bash
export KEY=sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20

# Test new vLLM through router
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "model": "qwen3.6-new-router",
    "messages": [{"role": "user", "content": "Hello, test message"}],
    "max_tokens": 50
  }'

# Compare with existing
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "model": "qwen3.6-vllm-router",
    "messages": [{"role": "user", "content": "Hello, test message"}],
    "max_tokens": 50
  }'
```

**Performance Comparison**:
```bash
# Test prefix caching improvement (run same prompt twice)
time curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "model": "qwen3.6-new-router",
    "messages": [{"role": "system", "content": "You are a helpful assistant."}, {"role": "user", "content": "What is 2+2?"}],
    "max_tokens": 20
  }'

# Second request should be 2-10x faster with prefix caching
time curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "model": "qwen3.6-new-router",
    "messages": [{"role": "system", "content": "You are a helpful assistant."}, {"role": "user", "content": "What is 3+3?"}],
    "max_tokens": 20
  }'
```

**GPU Memory Check**:
```bash
nvidia-smi

# You should see:
# - Existing vLLM: ~63GB
# - New vLLM: ~63GB
# - Total: ~126GB (EXCEEDS 97GB - this is for testing only!)
```

⚠️ **Warning**: Running both vLLM instances simultaneously will exceed GPU memory. This is only for short testing. Proceed to Phase 2 quickly.

#### Step 1.3: Rollback Test

**If anything is wrong**:
```bash
# Disable new vLLM
nano .env
# Set: ENABLE_VLLM=false

# Redeploy
./scripts/deploy.sh

# Verify existing still works
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model": "qwen3.6-vllm-router", "messages": [{"role": "user", "content": "test"}]}'
```

---

### Phase 2: Replace Existing vLLM (Hot Swap)

**Objective**: Stop existing containers and switch to new vLLM on same ports.

⚠️ **Critical**: This will cause ~2-5 minutes of downtime for vLLM during model loading.

#### Step 2.1: Stop Existing vLLM

```bash
# Stop existing containers
docker stop vllm-router
docker stop vllm-qwen36

# Verify stopped
docker ps | grep vllm
```

#### Step 2.2: Reconfigure New vLLM to Use Production Ports

Edit `.env`:
```bash
# Use production ports
VLLM_PORT=11502  # Same as existing vllm-qwen36
VLLM_ROUTER_PORT=11500  # Same as existing vllm-router
```

#### Step 2.3: Deploy New vLLM

```bash
cd /home/crimson/projects/gpu-inference-stack
./scripts/deploy.sh
```

Wait for model loading (5-10 minutes for 35B model):
```bash
# Watch logs
sg docker -c "docker logs -f vllm"

# Look for: "Avg prompt throughput" and health checks passing
```

#### Step 2.4: Update LiteLLM Configuration

Edit `config/litellm/config.yaml`:
```yaml
# Option A: Use Docker network names (recommended)
- model_name: qwen3.6-vllm-router
  litellm_params:
    model: openai/qwen3.6
    api_base: http://vllm-router:8080/v1  # Changed from host.docker.internal
    
- model_name: qwen3.6-vllm-direct
  litellm_params:
    model: openai/qwen3.6
    api_base: http://vllm:8000/v1  # Changed from host.docker.internal

# Option B: Keep using host ports (for external direct access)
- model_name: qwen3.6-vllm-router
  litellm_params:
    model: openai/qwen3.6
    api_base: http://host.docker.internal:11500/v1
```

Restart LiteLLM:
```bash
sg docker -c "docker compose restart litellm"
```

#### Step 2.5: Verify Migration

**Test all access patterns**:
```bash
export KEY=sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20

# 1. Via LiteLLM (primary)
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model": "qwen3.6-vllm-router", "messages": [{"role": "user", "content": "test"}], "max_tokens": 20}'

# 2. Direct to router (external)
curl -X POST http://localhost:11500/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3.6", "messages": [{"role": "user", "content": "test"}], "max_tokens": 20}'

# 3. Direct to vLLM (external)
curl -X POST http://localhost:11502/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3.6", "messages": [{"role": "user", "content": "test"}], "max_tokens": 20}'
```

**Check GPU memory**:
```bash
nvidia-smi

# Should show: ~63GB (same as before, single vLLM instance)
```

**Monitor metrics**:
- Grafana: http://localhost:3001
- Check latency, throughput, cache hit rate

#### Step 2.6: Rollback if Needed

**If migration fails**:
```bash
# Stop new vLLM
sg docker -c "docker compose down vllm vllm-router"

# Restart existing containers
docker start vllm-qwen36
docker start vllm-router

# Verify existing works
curl http://localhost:11500/health
curl http://localhost:11502/health

# Update LiteLLM config back to host.docker.internal if needed
sg docker -c "docker compose restart litellm"
```

---

### Phase 3: LiteLLM-Only Access (Recommended)

**Objective**: Consolidate all access through LiteLLM for better observability, caching, and management.

#### Step 3.1: Identify Direct Access Clients

```bash
# Check nginx logs for direct access (from existing router)
docker logs vllm-router --tail 100 | grep -v "127.0.0.1"

# Check vLLM logs for direct access
docker logs vllm --tail 100 | grep "POST /v1"
```

#### Step 3.2: Update Client Applications

For each client using direct access:

**Before** (direct access):
```python
# Client code using direct access
openai.api_base = "http://gpu-server:11500/v1"
response = openai.ChatCompletion.create(
    model="qwen3.6",
    messages=[{"role": "user", "content": "Hello"}]
)
```

**After** (via LiteLLM):
```python
# Client code using LiteLLM
openai.api_base = "http://gpu-server:8080/v1"
openai.api_key = "sk-f65b74f8ec1e386d7447fc87da4558c9a65e21c6abe3de360f7baea23e3c1f20"
response = openai.ChatCompletion.create(
    model="qwen3.6-vllm-router",  # Model name includes suffix now
    messages=[{"role": "user", "content": "Hello"}]
)
```

#### Step 3.3: Close Direct Access Ports (Optional)

After all clients migrated to LiteLLM:

Edit `docker-compose.yml`:
```yaml
vllm:
  # Remove or comment out external port mapping
  # ports:
  #   - "${VLLM_PORT:-11502}:8000"
  # Service still accessible within Docker network

vllm-router:
  # Remove or comment out external port mapping
  # ports:
  #   - "${VLLM_ROUTER_PORT:-11500}:8080"
```

Redeploy:
```bash
./scripts/deploy.sh
```

**Benefits**:
- ✅ All requests go through LiteLLM (observability)
- ✅ Unified caching across all clients
- ✅ Rate limiting and cost tracking
- ✅ Model fallbacks and load balancing
- ✅ Single authentication point

#### Step 3.4: Configure LiteLLM Features

**Enable advanced features** in `config/litellm/config.yaml`:

```yaml
litellm_settings:
  # Already enabled
  cache: true
  cache_params:
    type: redis
    host: redis
    port: 6379
    ttl: 600

  # Add rate limiting
  default_team_settings:
    - team_id: default
      max_parallel_requests: 100
      tpm_limit: 100000
      rpm_limit: 10000

router_settings:
  # Enable model fallbacks
  routing_strategy: least-busy
  
  # Fallback chain: large model -> small model
  model_group_alias:
    qwen-large:
      - qwen3.6-vllm-router
      - qwen2.5-7b-ollama-native  # Fallback to smaller model
```

**Test fallback**:
```bash
# Stop vLLM
docker stop vllm

# Request should fallback to Ollama
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model": "qwen-large", "messages": [{"role": "user", "content": "test"}]}'

# Restart vLLM
docker start vllm
```

---

## 📊 Comparison: Before vs After

| Feature | Before (Existing) | After (New) |
|---------|-------------------|-------------|
| **Model** | Qwen3.6-35B-A3B-FP8 | ✅ Same |
| **GPU Memory** | 65% (~63GB) | ✅ Same |
| **Max Sequences** | 62 | ✅ Same |
| **Expert Parallel** | ✅ Enabled | ✅ Enabled |
| **Auto Tool Choice** | ✅ Enabled | ✅ Enabled |
| **Reasoning Mode** | ✅ Enabled | ✅ Enabled |
| **Tool Parser** | ✅ qwen3_xml | ✅ qwen3_xml |
| **Prefix Caching** | ❌ Disabled | ✅ **Enabled (2-10x faster!)** |
| **Chunked Prefill** | ❌ Not enabled | ✅ **Enabled (lower TTFT)** |
| **Management** | External | ✅ **Integrated with stack** |
| **Monitoring** | Basic | ✅ **Full Prometheus/Grafana** |
| **Backup/Restore** | Manual | ✅ **Automated scripts** |
| **Configuration** | Hardcoded | ✅ **Environment-based** |
| **Health Checks** | Python check | ✅ **Same (compatible)** |
| **Router** | ✅ Nginx+NJS | ✅ **Same architecture** |
| **Updates** | Manual | ✅ **./scripts/update.sh** |

---

## 🎯 Success Criteria

Phase 1 Success:
- [ ] New vLLM loads model successfully
- [ ] Health checks pass
- [ ] Inference works through LiteLLM
- [ ] Prefix caching shows performance improvement
- [ ] Can rollback cleanly

Phase 2 Success:
- [ ] Old containers stopped gracefully
- [ ] New vLLM running on production ports (11500, 11502)
- [ ] All three access patterns work (LiteLLM, router, direct)
- [ ] GPU memory stable at ~63GB
- [ ] No errors in logs
- [ ] Monitoring dashboards show data

Phase 3 Success:
- [ ] All clients updated to use LiteLLM
- [ ] No direct access to vLLM/router ports
- [ ] Caching hit rate > 20%
- [ ] Fallback mechanism tested and working
- [ ] Prometheus alerts configured

---

## 🚨 Troubleshooting

### Issue: New vLLM won't start

**Symptoms**:
```
docker ps shows vllm with status "Restarting"
```

**Debug**:
```bash
# Check logs
sg docker -c "docker logs vllm"

# Common issues:
# - Model download failed (check HF_HOME)
# - OOM during model load (reduce GPU memory utilization)
# - Wrong model path (check VLLM_MODEL)
```

**Fix**:
```bash
# Reduce memory if OOM
nano .env
# Set: VLLM_GPU_MEMORY_UTILIZATION=0.60

# Clear cache and retry
rm -rf ./data/vllm/cache/*
./scripts/deploy.sh
```

### Issue: Router can't reach vLLM

**Symptoms**:
```
curl http://localhost:11500/v1/models → 502 Bad Gateway
```

**Debug**:
```bash
# Check if vLLM is healthy
curl http://localhost:11502/health

# Check Docker network
sg docker -c "docker exec vllm-router ping -c 1 vllm"

# Check router logs
sg docker -c "docker logs vllm-router"
```

**Fix**:
```bash
# Recreate router
sg docker -c "docker compose up -d --force-recreate vllm-router"
```

### Issue: LiteLLM can't reach new services

**Symptoms**:
```
curl http://localhost:8080/v1/chat/completions → Connection error
```

**Debug**:
```bash
# Check LiteLLM logs
sg docker -c "docker logs litellm"

# Test from LiteLLM container
sg docker -c "docker exec litellm curl http://vllm:8000/health"
sg docker -c "docker exec litellm curl http://vllm-router:8080/health"
```

**Fix**:
```bash
# Ensure all containers on same network
sg docker -c "docker compose restart litellm"
```

### Issue: Performance worse than before

**Check**:
```bash
# Verify prefix caching is enabled
sg docker -c "docker exec vllm cat /proc/1/cmdline" | tr '\0' '\n' | grep prefix

# Should see: --enable-prefix-caching

# Check cache hit rate in Grafana
# Or check vLLM logs:
sg docker -c "docker logs vllm" | grep "cache hit rate"
```

---

## 📝 Rollback Procedures

### Full Rollback to Original State

```bash
# 1. Stop new stack
cd /home/crimson/projects/gpu-inference-stack
./scripts/stop.sh

# 2. Start original containers
docker start vllm-qwen36
docker start vllm-router

# 3. Verify
curl http://localhost:11500/health
curl http://localhost:11502/health

# 4. Test via LiteLLM (should still work)
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model": "qwen3.6-vllm-router", "messages": [{"role": "user", "content": "test"}]}'
```

---

## 🎓 Post-Migration Optimization

After successful migration:

1. **Tune vLLM parameters**:
   ```bash
   # Monitor and adjust in .env
   VLLM_MAX_NUM_SEQS=128  # Increase if latency is low
   VLLM_GPU_MEMORY_UTILIZATION=0.70  # Increase if VRAM allows
   ```

2. **Configure Prometheus alerts**:
   - GPU memory > 90%
   - Request latency > 5s (p99)
   - Cache hit rate < 10%
   - Service downtime

3. **Set up automated backups**:
   ```bash
   # Daily config backups
   crontab -e
   # Add: 0 2 * * * /home/crimson/projects/gpu-inference-stack/scripts/backup-config.sh
   ```

4. **Remove old containers**:
   ```bash
   # After confirming new stack is stable for 1 week
   docker rm vllm-qwen36
   docker rm vllm-router
   ```

---

## ✅ Migration Complete!

You now have:
- ✅ Unified management via gpu-inference-stack
- ✅ Improved performance (prefix caching + chunked prefill)
- ✅ Better monitoring (Prometheus/Grafana)
- ✅ Centralized access through LiteLLM
- ✅ Automated deployment and updates
- ✅ Easy scaling and configuration

**Next**: See `EXISTING_SERVICES.md` for complete service documentation.
