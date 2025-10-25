# Scripts Reference

Operational scripts for NIM-GKE deployment and management.

---

## Deployment Scripts

### `deploy_nim_gke.sh`

**Purpose**: Main deployment script. Creates GKE cluster, GPU node pool, and NIM deployment.

**Prerequisites**: NGC API key set, gcloud authenticated, GPU quota approved.

**Usage**:
```bash
export NGC_CLI_API_KEY='your-key'
./scripts/deploy_nim_gke.sh
```

**Duration**: 25-35 minutes.

**What it does**:
1. Validates tools (gcloud, kubectl, helm)
2. Creates GKE cluster (e2-standard-4 control plane)
3. Creates GPU node pool (g2-standard-4 + L4)
4. Fetches NIM Helm chart
5. Creates namespace and secrets
6. Deploys NIM StatefulSet
7. Waits for pod ready

**Output**: Running NIM pod, accessible via port-forward.

---

### `deploy_nim_production.sh`

**Purpose**: Production-grade deployment with autoscaling, monitoring, and hardened configuration.

**Differences from standard deploy**:
- Autoscaling enabled (0-2 nodes)
- Resource limits enforced
- Health checks tuned for production
- Comprehensive error handling

**Usage**:
```bash
./scripts/deploy_nim_production.sh
```

**Recommended for**: Staging, production environments.

---

### `deploy_nim_only.sh`

**Purpose**: Deploy NIM to existing cluster (cluster already created).

**Usage**:
```bash
# Assumes cluster 'nim-demo' exists
./scripts/deploy_nim_only.sh
```

**Use case**: Redeploy after `helm uninstall`.

---

## Validation Scripts

### `setup_environment.sh`

**Purpose**: Prerequisite validation and environment setup.

**Usage**:
```bash
./scripts/setup_environment.sh
```

**Checks**:
- Tool installation (gcloud, kubectl, helm)
- GCP authentication
- Required APIs enabled
- GPU quotas
- NGC API key validity
- Network connectivity

**Recommendation**: Run before first deployment.

---

### `gke_nim_prereqs.sh`

**Purpose**: Lightweight prerequisite check (subset of setup_environment.sh).

**Usage**:
```bash
./scripts/gke_nim_prereqs.sh
```

**Use case**: Quick validation before deployment.

---

## Testing Scripts

### `test_nim.sh`

**Purpose**: Basic functionality test (health check, model list, single inference).

**Prerequisites**: Port-forward active (`kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim`).

**Usage**:
```bash
./scripts/test_nim.sh
```

**Output**:
```
✅ Pod is running
✅ Models endpoint accessible
✅ Chat completion successful
```

---

### `test_nim_production.sh`

**Purpose**: Comprehensive integration tests (health, API, load testing, monitoring).

**Tests**:
1. Health endpoint (`/v1/health/ready`)
2. Model list (`/v1/models`)
3. Single inference
4. Load test (5 concurrent requests)
5. Resource monitoring (GPU, CPU, memory)
6. Performance metrics (tokens/sec)

**Usage**:
```bash
./scripts/test_nim_production.sh
```

**Duration**: ~5 minutes.

**Output**: Test report with pass/fail status, performance metrics.

---

## Operations Scripts

### `monitor_deployment.sh`

**Purpose**: Monitor all IaaS and PaaS components every minute for up to 60 minutes.

**Usage**:
```bash
./scripts/monitor_deployment.sh
```

**Monitors**:
- GKE cluster status
- Node pools (default, gpupool)
- GPU nodes
- Pods (status, readiness)
- Services, secrets, events
- Deployment summary
- Cost estimate

**Output**: Timestamped status reports. Exits when pod reaches Ready state.

---

### `cleanup.sh`

**Purpose**: Delete all resources to stop costs.

**Usage**:
```bash
./scripts/cleanup.sh
```

**Deletes**:
- GKE cluster (includes all node pools)
- Persistent volumes
- Load balancers (if created)

**Warning**: Irreversible. Model cache lost.

**Cost after cleanup**: $0/hour.

---

### `add_gpu_nodepool.sh`

**Purpose**: Add GPU node pool to existing cluster.

**Usage**:
```bash
./scripts/add_gpu_nodepool.sh
```

**Use case**: Cluster exists but GPU pool missing.

---

## Configuration Scripts

### `set_ngc_key.sh` (generated from template)

**Purpose**: Set NGC API key environment variable.

**Usage**:
```bash
# Copy template
cp examples/set_ngc_key.sh.template set_ngc_key.sh

# Edit with your key
vim set_ngc_key.sh

# Source it
source ./set_ngc_key.sh
```

**Security**: File excluded by .gitignore.

---

## Script Conventions

### Error Handling

All scripts use `set -euo pipefail`:
- `-e`: Exit on first error
- `-u`: Exit on undefined variable
- `-o pipefail`: Catch errors in pipes

### Idempotency

Scripts check resource existence before creating:
```bash
if gcloud container clusters describe $CLUSTER_NAME &>/dev/null; then
  echo "Cluster exists, skipping creation"
else
  gcloud container clusters create $CLUSTER_NAME
fi
```

### Configuration Variables

Top of each script:
```bash
export PROJECT_ID="your-gcp-project"
export REGION="us-central1"
export ZONE="us-central1-a"
export CLUSTER_NAME="nim-demo"
```

**Customize**: Edit these before running.

### Logging

Consistent format:
- `✅` : Success
- `❌` : Error
- `⏳` : In progress
- `⚠️` : Warning

---

## Execution Order

**First-time deployment**:
```bash
1. ./scripts/setup_environment.sh
2. ./scripts/deploy_nim_gke.sh
3. kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim &
4. ./scripts/test_nim.sh
```

**Redeployment** (after cleanup):
```bash
1. ./scripts/deploy_nim_gke.sh  # Recreates everything
```

**NIM-only redeploy** (cluster exists):
```bash
1. ./scripts/deploy_nim_only.sh
```

**Cleanup**:
```bash
1. ./scripts/cleanup.sh
```

---

## Troubleshooting Scripts

If scripts fail, check:

1. **NGC API key**: `echo $NGC_CLI_API_KEY`
2. **gcloud auth**: `gcloud auth list`
3. **GCP project**: `gcloud config get-value project`
4. **GPU quota**: `gcloud compute regions describe us-central1 | grep L4`

**Logs**: Scripts output to stdout. Redirect to file:
```bash
./scripts/deploy_nim_gke.sh 2>&1 | tee deployment.log
```

---

## Script Dependencies

| Script | Requires |
|--------|----------|
| `deploy_nim_gke.sh` | gcloud, kubectl, helm, NGC key |
| `deploy_nim_production.sh` | Same as above |
| `deploy_nim_only.sh` | Existing cluster |
| `setup_environment.sh` | gcloud |
| `test_nim.sh` | Port-forward active |
| `test_nim_production.sh` | Port-forward active |
| `monitor_deployment.sh` | kubectl configured |
| `cleanup.sh` | gcloud |

---

## Security Best Practices

1. **Never commit `set_ngc_key.sh`**: Excluded by .gitignore
2. **Rotate NGC keys periodically**: Every 90 days
3. **Use least-privilege GCP service accounts**: Not Owner role
4. **Validate inputs**: Scripts check variables before proceeding
5. **Avoid hardcoded secrets**: Use environment variables

---

**Last updated**: October 2025

