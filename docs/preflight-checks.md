# Pre-flight Checks

The `make start` command runs comprehensive pre-flight checks before starting containers.

## What Gets Checked

### Tier 1 - Critical (auto-fix where possible)
- **Container name conflicts** - Removes old containers blocking startup
- **Port conflicts** - Stops our old containers, errors on external processes
- **Disk space** - Warns if <5GB free

### Tier 2 - Important
- **Docker daemon** - Verifies Docker is running and responsive
- **GPU availability** - Checks nvidia-smi and free GPU memory
- **Docker Compose version** - Warns if <2.0

### Tier 3 - Nice to have
- **Volume paths** - Auto-creates missing directories
- **Network conflicts** - Removes stale Docker networks
- **Required images** - Shows what will be pulled

## Auto-fix Behavior

Checks auto-fix when safe:
- Container conflicts → removes old containers
- Port conflicts (our containers) → stops them
- Missing volume paths → creates directories
- Stale networks → removes and recreates

Checks that warn only:
- Low disk space → suggests cleanup
- GPU memory low → shows processes
- Old Compose version → suggests upgrade

Checks that error:
- Docker daemon down → suggests systemctl
- Port conflicts (external) → shows remediation

## Environment Variables

| Variable | Default | Effect |
|----------|---------|--------|
| `SKIP_PREFLIGHT` | `0` | Skip all pre-flight checks |
| `PREFLIGHT_STRICT` | `0` | Treat warnings as errors |
| `PREFLIGHT_NO_AUTOFIX` | `0` | Show fixes but don't apply (dry-run) |

## Examples

### Normal startup
```bash
make start
```

Output:
```
Starting profile 85
Running pre-flight checks...

  ✓ Docker daemon responsive
  ✓ GPU available (10245 MB free)
  ✓ Disk space OK (42 GB free)
  ✓ No container name conflicts
  ✓ Ports available (8 checked)
  ✓ All checks passed

[continues with docker compose up...]
```

### With auto-fix
```bash
make start
```

Output:
```
Running pre-flight checks...

  ✓ Docker daemon responsive
  ⚠ Container name conflict: ollama (eb67490a, created 3 months ago)
  → Removing conflicting container... done
  ✓ All checks passed
```

### Skip checks
```bash
SKIP_PREFLIGHT=1 make start
```

### Dry-run mode
```bash
PREFLIGHT_NO_AUTOFIX=1 make start
```

Shows what would be fixed without actually doing it.

### Strict mode
```bash
PREFLIGHT_STRICT=1 make start
```

Treats warnings (low disk, low GPU memory) as errors and halts.

## Troubleshooting

### Port conflict with external process

Error:
```
┌─────────────────────────────────────────────────────────┐
│ ✗ Pre-flight check failed: Port conflict                │
├─────────────────────────────────────────────────────────┤
│                                                         │
│ Port 8080 is already in use by:                        │
│   nginx (PID 1234)                                     │
│                                                         │
│ To fix:                                                │
│   1. Stop the conflicting process:                     │
│      sudo kill 1234                                    │
│   ...                                                  │
└─────────────────────────────────────────────────────────┘
```

Fix: Follow the remediation steps in the error box.

### GPU memory exhausted

Warning:
```
! GPU memory low: 234 MB free
  Current processes:
  GPU  PID    Process
  0    1234   python (32000 MB)
```

Fix: Stop other GPU processes or use `PREFLIGHT_STRICT=0` (default) to continue anyway.
