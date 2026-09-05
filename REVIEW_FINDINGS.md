# Code Review Findings - GPU Inference Stack

Review Date: 2026-09-05
Reviewer: Claude

## Executive Summary

The implementation is **mostly production-ready** with some **critical port conflicts** and **minor bugs** that need fixing before deployment.

**Status**: ⚠️ **NEEDS FIXES BEFORE DEPLOYMENT**

---

## 🔴 CRITICAL ISSUES (Must Fix)

### 1. Port Conflicts

**Problem**: Some configured ports are already in use on the server.

**Conflicting Ports**:
- `9091` - Prometheus (already running a Prometheus instance)
- `8081` - LiteLLM Admin (service listening but not responding)

**Evidence**:
```bash
$ ss -tlnp | grep -E ":(8081|9091)"
LISTEN 0      4096          0.0.0.0:9091       0.0.0.0:*
LISTEN 0      4096          0.0.0.0:8081       0.0.0.0:*
```

**Impact**: Deployment will fail when trying to bind these ports.

**Fix Required**:
```bash
# In .env, change:
PROMETHEUS_PORT=9092  # Instead of 9091
# Remove LITELLM_ADMIN_PORT (not used in docker-compose.yml)
```

---

### 2. Wrong Embeddings Port in LiteLLM Config

**Location**: `config/litellm/config.yaml:102`

**Problem**: Embeddings API base points to port 8080, which is LiteLLM's own port!

```yaml
# Current (WRONG):
api_base: http://host.docker.internal:8080

# Should be:
api_base: http://host.docker.internal:8082  # Or check actual embeddings port
```

**Impact**: Embeddings requests will fail or create infinite loops.

**Fix Required**: Update embeddings API base to correct port.

---

### 3. Docker Permission Issue

**Problem**: User `crimson` not in docker group.

**Evidence**:
```
permission denied while trying to connect to the docker API
```

**Impact**: Scripts will fail to run without sudo.

**Fix Required**:
```bash
sudo usermod -aG docker crimson
newgrp docker  # Or logout/login
```

---

## 🟡 MEDIUM PRIORITY ISSUES

### 4. Missing Services in Deploy Script

**Location**: `scripts/deploy.sh:60`

**Problem**: Redis and Postgres are not included in profiles list, but they're required for LiteLLM.

**Current**:
```bash
PROFILES="litellm,prometheus,grafana,node-exporter,dcgm-exporter"
```

**Issue**: Redis and Postgres don't have profiles in docker-compose.yml, so they'll always run. This is actually CORRECT, but the script doesn't document it clearly.

**Recommendation**: Add comment explaining that Redis/Postgres always run as LiteLLM dependencies.

---

### 5. Health Check Wait Time Too Short

**Location**: `scripts/deploy.sh:91`

**Problem**: Only waits 10 seconds for services to start. vLLM can take 2-5 minutes to load models.

**Current**:
```bash
sleep 10
```

**Impact**: Health check will show services as unhealthy even though they're still starting.

**Fix Recommended**:
```bash
echo "Waiting for services to start (this may take 2-5 minutes for vLLM)..."
sleep 30  # Initial wait
# Then do actual health checks with retries
```

---

### 6. Redis Health Check in health-check.sh

**Location**: `scripts/health-check.sh:70`

**Problem**: Tries to check Redis via HTTP, which doesn't work.

**Current**:
```bash
check_endpoint "Redis" "http://localhost:6379" 000  # Redis doesn't respond to HTTP
```

**Fix Recommended**: Skip Redis HTTP check or use redis-cli from within container:
```bash
docker exec redis redis-cli ping > /dev/null 2>&1 && echo "✓ Redis OK"
```

---

### 7. Docker Compose Override Not Included in Scripts

**Location**: `scripts/deploy.sh`, `scripts/health-check.sh`

**Problem**: Commands don't automatically include `docker-compose.override.yml`.

**Current**: Docker Compose auto-loads override files, so this actually works.

**Status**: Not a bug, but could be more explicit.

---

## 🟢 MINOR ISSUES / IMPROVEMENTS

### 8. Obsolete Docker Compose Version Directive

**Location**: `docker-compose.yml:1`, `docker-compose.override.yml:1`

**Issue**: `version: '3.8'` is obsolete in modern Docker Compose.

**Impact**: Just a warning, not a breaking issue.

**Fix**: Remove `version:` line from both files.

---

### 9. Security: Password Displayed in Deploy Script

**Location**: `scripts/deploy.sh:104`

**Problem**: Grafana password shown in deployment output.

**Current**:
```bash
echo "  Grafana:     http://localhost:${GRAFANA_PORT:-3000} (admin/${GRAFANA_ADMIN_PASSWORD:-admin})"
```

**Fix Recommended**: Don't display password:
```bash
echo "  Grafana:     http://localhost:${GRAFANA_PORT:-3000} (admin/***)"
```

---

### 10. Missing Postgres Health Check in health-check.sh

**Problem**: Script doesn't verify Postgres (required for LiteLLM).

**Fix Recommended**: Add:
```bash
docker exec postgres pg_isready -U litellm > /dev/null 2>&1 && echo "✓ Postgres OK"
```

---

### 11. vLLM Command Boolean Expansion

**Location**: `docker-compose.yml:82-83`

**Potential Issue**: Bash parameter expansion in YAML might not work as expected.

**Current**:
```yaml
${VLLM_ENABLE_PREFIX_CACHING:+--enable-prefix-caching}
```

**Testing Needed**: Verify this works correctly when env var is true/false.

**Alternative**: Use conditional in entrypoint script or set full command in .env.

---

## ✅ THINGS THAT LOOK GOOD

1. **Architecture**: Clean separation of concerns, modular design
2. **Documentation**: Comprehensive and well-organized
3. **Server Profiles**: Good abstraction for different GPU configs
4. **Monitoring Stack**: Complete setup with Prometheus + Grafana
5. **Health Checks**: Properly defined for all services
6. **Volume Management**: Correct use of named volumes and bind mounts
7. **Network Configuration**: Isolated Docker network
8. **Resource Limits**: Configurable GPU memory allocation
9. **Logging**: Proper log rotation configured
10. **Git Setup**: Clean repository structure, good .gitignore

---

## 📊 RESOURCE ANALYSIS

### Current Server Status (crimson-llm2)

**GPU Usage**:
- VRAM: 90.9GB/97GB (93% used)
- Utilization: 100%
- Temperature: 86°C

**Docker Stack Allocation** (from .env):
- vLLM GPU Memory: 20% (~19GB of 97GB)
- Conflicts: May compete with native vLLM using 65% (~63GB)
- **Total**: Could exceed 100% VRAM!

**Risk**: 🔴 **GPU OUT OF MEMORY**

**Recommendation**:
1. Reduce Docker vLLM to 10% (VLLM_GPU_MEMORY_UTILIZATION=0.10)
2. Or disable Docker vLLM initially (ENABLE_VLLM=false)
3. Monitor with `watch nvidia-smi` after deployment

### Disk Space

- Total: 1.8TB
- Used: 1.5TB (92%)
- Available: 150GB

**Status**: ✅ Adequate (but monitor for model downloads)

---

## 🔧 REQUIRED FIXES BEFORE DEPLOYMENT

### Fix #1: Update Ports (.env)

```bash
# Change from:
PROMETHEUS_PORT=9091
LITELLM_ADMIN_PORT=8081

# To:
PROMETHEUS_PORT=9092
# (Remove LITELLM_ADMIN_PORT - not used)
```

### Fix #2: Update Embeddings Port (config/litellm/config.yaml)

```yaml
# Line 102, change from:
api_base: http://host.docker.internal:8080

# To (check actual port first):
api_base: http://host.docker.internal:8082
```

### Fix #3: Add User to Docker Group

```bash
sudo usermod -aG docker crimson
newgrp docker
```

### Fix #4: Reduce GPU Memory Allocation (.env)

```bash
# Change from:
VLLM_GPU_MEMORY_UTILIZATION=0.20

# To:
VLLM_GPU_MEMORY_UTILIZATION=0.10

# Or disable initially:
ENABLE_VLLM=false
```

### Fix #5: Update Deploy Script (scripts/deploy.sh)

```bash
# Line 91, change from:
sleep 10

# To:
sleep 30

# Line 104, change from:
echo "  Grafana:     http://localhost:${GRAFANA_PORT:-3000} (admin/${GRAFANA_ADMIN_PASSWORD:-admin})"

# To:
echo "  Grafana:     http://localhost:${GRAFANA_PORT:-3000} (admin/***)"
```

### Fix #6: Update Health Check Script (scripts/health-check.sh)

```bash
# Line 70, replace Redis HTTP check with:
echo -n "Checking Redis... "
if docker exec redis redis-cli ping > /dev/null 2>&1; then
    echo -e "${GREEN}✓ OK${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
fi
```

---

## 📋 RECOMMENDED TESTING SEQUENCE

After applying fixes:

1. **Validate Configuration**:
   ```bash
   docker compose config > /dev/null && echo "✓ Config valid"
   ```

2. **Check Ports Available**:
   ```bash
   for port in 8080 3001 9092 11435 8001 6380; do
       ss -tln | grep -q ":$port " && echo "⚠️  Port $port in use" || echo "✓ Port $port free"
   done
   ```

3. **Deploy Core Services Only** (no GPU services first):
   ```bash
   ENABLE_OLLAMA=false ENABLE_VLLM=false ./scripts/deploy.sh
   ```

4. **Verify LiteLLM Can Access Native Services**:
   ```bash
   docker exec litellm curl -s http://host.docker.internal:11437/api/tags
   docker exec litellm curl -s http://host.docker.internal:8000/health
   ```

5. **Test LiteLLM API**:
   ```bash
   curl http://localhost:8080/v1/models \
     -H "Authorization: Bearer sk-f65b..."
   ```

6. **Enable GPU Services Gradually**:
   ```bash
   # First enable just Ollama Docker
   # Edit .env: ENABLE_OLLAMA=true
   ./scripts/deploy.sh

   # Monitor GPU usage
   watch nvidia-smi

   # Then enable vLLM if VRAM permits
   ```

---

## 🎯 PRIORITY SUMMARY

**Before Deployment**:
- [ ] Fix port conflicts (Critical)
- [ ] Fix embeddings API base (Critical)
- [ ] Add user to docker group (Critical)
- [ ] Reduce GPU memory allocation (Critical)
- [ ] Update deploy script wait time (Medium)
- [ ] Fix Redis health check (Medium)

**After Successful Deployment**:
- [ ] Remove obsolete version directives (Minor)
- [ ] Add Postgres health check (Minor)
- [ ] Test vLLM boolean expansion (Minor)

---

## 💡 OVERALL ASSESSMENT

**Code Quality**: ⭐⭐⭐⭐☆ (4/5)
- Well-structured, comprehensive documentation
- Good separation of concerns
- Minor bugs that are easy to fix

**Production Readiness**: ⚠️ **WITH FIXES**
- Critical port conflicts must be resolved
- GPU memory allocation needs adjustment
- After fixes: Ready for production use

**Recommendation**: **Fix critical issues, then deploy incrementally** (core services first, GPU services after monitoring resource usage).
