# Scripts Reference

Operational scripts for NIM-GKE deployment and management. Every script
sources `config.env` for settings (`PROJECT_ID` required, no default; every
other value has a default and can be overridden by exporting it first).

---

## Deployment Scripts

### `deploy_nim_gke.sh`

**Purpose**: Main deployment script. Creates GKE cluster, GPU node pool, and NIM deployment. This is the measured path (see `docs/runs/2026-09-27-measured-run.md`).

**Prerequisites**: `NGC_API_KEY` set, gcloud authenticated, GPU quota approved. Run `preflight.sh` first.

**Usage**:
```bash
export NGC_API_KEY='your-key'   # NGC_CLI_API_KEY accepted as a fallback
export PROJECT_ID='your-gcp-project'
./scripts/deploy_nim_gke.sh
```

**Duration**: measured 20 m 19 s, script start to pod Ready (docs/runs/2026-09-27-measured-run.md).

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

**Purpose**: Alternate deployment with an autoscaling GPU node pool (0-2 nodes) and a system pool with a minimum of 1 node. **Not measured** — no timing or cost numbers exist for this path.

**Differences from `deploy_nim_gke.sh`**:
- GPU node pool autoscales 0-2 nodes; `deploy_nim_gke.sh` uses a fixed node count
- Resource limits enforced
- Health checks tuned for production

**Usage**:
```bash
./scripts/deploy_nim_production.sh
```

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

### `preflight.sh`

**Purpose**: Six read-only checks before deploying: NGC key present, gcloud auth, image tag reachable, chart fetch, L4 quota, no existing cluster of the target name. A seventh check runs when `AUTOSCALE=1`: project `GPUS_ALL_REGIONS` and regional `NVIDIA_L4_GPUS` quota must each have at least `MAX_GPU_NODES * GPU_COUNT` available (2 GPUs of quota for `run_measured.sh --two-nodes`); fails with the limit/usage numbers in the message if not.

**Usage**:
```bash
./scripts/preflight.sh
```

**Recommendation**: Run before `deploy_nim_gke.sh`. This is the first step of the measured run order.

---

### `setup_environment.sh`

**Purpose**: Broader prerequisite validation and environment setup (tools, APIs, quotas, NGC key, network connectivity).

**Usage**:
```bash
./scripts/setup_environment.sh
```

---

### `gke_nim_prereqs.sh`

**Purpose**: Lightweight prerequisite check (subset of `setup_environment.sh`).

**Usage**:
```bash
./scripts/gke_nim_prereqs.sh
```

---

## Testing Scripts

### `run_measured.sh`

**Purpose**: End-to-end measured-run runner: preflight -> deploy -> wait for
pod Ready -> save pod info -> port-forward -> bench -> cleanup -> final
checks. Rebuilt from the ad hoc 2026-09-27 run script with a timeout on the
Ready wait and a trap that always tears down, even on a failed deploy.

**Spends money**: creates a real GKE cluster with a GPU node pool. Always
run it somewhere you can watch, and expect it to bill for the run's
duration.

**Usage**:
```bash
export NGC_API_KEY='your-key'   # NGC_CLI_API_KEY accepted as a fallback
export PROJECT_ID='your-gcp-project'
./scripts/run_measured.sh OUT_DIR
```

**What it creates** (all under `OUT_DIR`): `phases.log` (UTC-timestamped
phase marks), `preflight.log`, `deploy.log`, `pod.json`, `pod.log`,
`port-forward.log`, `bench.log`, `bench.json`, `cleanup.log`,
`operations.txt`, `final-clusters.txt`, `final-disks.txt`,
`watchdog.pid`, `watchdog.log`, and `trap.log` (the trap's own output).

**Safety net**:
- An `EXIT`/`INT`/`TERM`/`HUP` trap tears down on every exit, including
  Ctrl-C and a closed terminal. It ignores further signals, writes only to
  files (`trap.log`), waits out any running GKE operation, and retries
  `cleanup.sh --yes` until the cluster is gone (`CLEANUP_RETRY_SEC`, default
  20 min). It then records final cluster/disk/operations state, prints
  `trap.log` to the terminal, and fails the run if the cluster or any
  `pvc-`/cluster-named disk is still present.
- A watchdog runs as a separate process in its own session, so closing the
  terminal or killing the runner's process group (even with SIGKILL) does
  not stop it. If the runner ends without a verified clean teardown, the
  watchdog takes over within seconds and retries cleanup itself. It also
  enforces an overall deadline (`WATCHDOG_SEC`, default: the sum of the
  phase timeouts plus 30 min). It only touches the cluster this run created
  (checked by `createTime`).
- The Ready wait has a timeout (default 30 min, `READY_TIMEOUT_SEC`); it no
  longer spins forever once a cluster is gone.

**`--autoscale` / `--two-nodes`** (unmeasured autoscale test path): adds a
GPU-node autoscale test on top of the same runner. `--autoscale` deploys with
`AUTOSCALE=1` (`deploy_nim_gke.sh` creates `gpupool` at 0 nodes with cluster
autoscaling, `--min-nodes=0 --max-nodes=${MAX_GPU_NODES}`), waits for the
cluster autoscaler to bring up one GPU node, then runs the normal Ready-wait
and bench, then scales the StatefulSet back to 0 and waits for the
autoscaler to remove the node before cleanup. `--two-nodes` (requires
`--autoscale` and `MAX_GPU_NODES>=2`, else exit 2) additionally scales the
StatefulSet to 2 replicas and waits for a second GPU node before scaling
back to 0. **Spends money for two GPUs** when `--two-nodes` is used (quota:
set `MAX_GPU_NODES=2` and have 2 L4s of quota; `preflight.sh` checks this
when `AUTOSCALE=1`, see below). Timeouts: `SCALE_UP_TIMEOUT_SEC` (default
1200s) for each node to become Ready, `SCALE_DOWN_TIMEOUT_SEC` (default
1800s, GKE does not document the scale-down wait) for the node count to
reach 0; any phase timeout marks `<phase> TIMEOUT` in `phases.log` and exits
1 (the trap still cleans up). `WATCHDOG_SEC` grows with the phases in use. Extra evidence files under `OUT_DIR`: `events.txt`
(appended at each phase end), `nodes-<phase>.txt` (one per phase), and
`autoscaler.json` (the `container.googleapis.com/cluster-autoscaler-visibility`
log for this cluster/run, via `gcloud logging read`; a failure to fetch it is
logged but does not fail the run). Without `--autoscale`, the run behaves
exactly as before.

---

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

**Output**: Test report with pass/fail status, performance metrics.

---

### `bench.py`

**Purpose**: Benchmark script used for the measured run (`docs/runs/2026-09-27-measured-run.md`): 20 requests at temperature 0, 5 of them streamed to measure time to first token, concurrency 1.

**Prerequisites**: Port-forward active.

**Usage**:
```bash
python3 scripts/bench.py
```

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

Prompts for confirmation unless stdin is not a terminal. For scripted runs,
skip the prompt:
```bash
./scripts/cleanup.sh --yes
```

**Order of operations**:
1. Uninstalls the Helm release
2. Deletes the PVC
3. Deletes the GKE cluster (all node pools)
4. Lists any leftover disks in the project, for manual review

**Warning**: Irreversible. Model cache lost.

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

Only the Helm install step is idempotent: `deploy_nim_gke.sh` runs
`helm upgrade --install`, safe to re-run against an existing release.
Cluster and node-pool creation are not idempotent; re-running against an
existing cluster of the same name fails.

### Configuration Variables

All scripts source `config.env`:
```bash
source "$(dirname "${BASH_SOURCE[0]}")/config.env"
```

`PROJECT_ID` has no default; scripts stop if it is unset. Every other
variable (`REGION`, `ZONE`, `CLUSTER_NAME`, `GPU_TYPE`,
`NODE_POOL_MACHINE_TYPE`, `CLUSTER_MACHINE_TYPE`, `NIM_CHART_VERSION`,
`NIM_RELEASE_NAME`, `NIM_NAMESPACE`, `AUTOSCALE`, `MAX_GPU_NODES`) has a
default in `config.env`. Override any value by exporting it before running a
script. `AUTOSCALE` (default `0`) and `MAX_GPU_NODES` (default `1`) drive
the unmeasured autoscale test path: see `deploy_nim_gke.sh` and
`run_measured.sh --autoscale`/`--two-nodes` above.

### Logging

Consistent format:
- `✅` : Success
- `❌` : Error
- `⏳` : In progress
- `⚠️` : Warning

---

## Execution Order

**Measured path (first-time deployment)**:
```bash
1. ./scripts/preflight.sh
2. ./scripts/deploy_nim_gke.sh
3. kubectl port-forward -n nim svc/my-nim-nim-llm 8000:8000 &
4. ./scripts/test_nim.sh          # or: python3 scripts/bench.py
5. ./scripts/cleanup.sh
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

1. **NGC API key**: `echo $NGC_API_KEY`
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
| `preflight.sh` | gcloud, NGC key |
| `deploy_nim_gke.sh` | gcloud, kubectl, helm, NGC key |
| `deploy_nim_production.sh` | Same as above |
| `deploy_nim_only.sh` | Existing cluster |
| `setup_environment.sh` | gcloud |
| `test_nim.sh` | Port-forward active |
| `bench.py` | Port-forward active |
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

**Measured run**: 2026-09-27 (`docs/runs/2026-09-27-measured-run.md`)

