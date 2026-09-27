#!/usr/bin/env bash
# Read-only preflight for the NIM-on-GKE measured run.
# Checks exactly the six items named in the run receipt's preflight gate:
# NGC key, auth, image tag, chart fetch, L4 quota, no cluster.
# Prints PASS/FAIL per check and exits non-zero if any check fails.
# Makes no cluster, no deploy, no write calls -- read-only against
# NGC/nvcr.io and GCP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.env
source "${SCRIPT_DIR}/config.env"
require_project_id

FAIL=0

check() {
  # check <name> <fn>
  local name="$1"; local fn="$2"
  local msg
  if msg="$("$fn" 2>&1)"; then
    echo "PASS: ${name}${msg:+ (${msg})}"
  else
    echo "FAIL: ${name}${msg:+ -- ${msg}}"
    FAIL=1
  fi
}

# 1. NGC_API_KEY set (value is never printed).
check_ngc_key() {
  if [[ -n "${NGC_API_KEY:-}" ]]; then
    echo "key is set"
    return 0
  fi
  echo "NGC_API_KEY (and NGC_CLI_API_KEY fallback) are unset"
  return 1
}

# 2. gcloud has an active account.
check_gcloud_auth() {
  local account
  account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>&1)" || {
    echo "gcloud auth list failed: ${account}"
    return 1
  }
  if [[ -z "${account}" ]]; then
    echo "no active gcloud account"
    return 1
  fi
  echo "active account ${account}"
  return 0
}

# 3. Image tag exists in nvcr.io.
# UNVERIFIED-method: this token-then-HEAD flow follows the documented NGC/nvcr.io
# docker-registry v2 auth pattern (proxy_auth -> bearer token -> HEAD manifest),
# but it has not been run live against a real key/registry in this session, so
# the exact field names/response shape are not confirmed end to end.
check_image_tag() {
  if [[ -z "${NGC_API_KEY:-}" ]]; then
    echo "skipped: NGC_API_KEY unset"
    return 1
  fi
  # NIM_IMAGE_REPO is like nvcr.io/nim/meta/llama3-8b-instruct; the repo path
  # for the registry API is everything after the "nvcr.io/" host.
  local repo_path="${NIM_IMAGE_REPO#nvcr.io/}"
  local token_json token
  token_json="$(ngc_curl -sf \
    "https://nvcr.io/proxy_auth?scope=repository:${repo_path}:pull" 2>&1)" || {
    echo "auth token request failed: ${token_json}"
    return 1
  }
  token="$(python3 -c 'import json,sys
d = json.load(sys.stdin)
print(d.get("token") or d.get("access_token") or "")' <<<"${token_json}" 2>/dev/null || true)"
  if [[ -z "${token}" || "${token}" == "None" ]]; then
    echo "could not parse bearer token from proxy_auth response"
    return 1
  fi
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
    --head "https://nvcr.io/v2/${repo_path}/manifests/${NIM_IMAGE_TAG}" 2>&1)" || {
    echo "manifest HEAD request failed"
    return 1
  }
  if [[ "${status}" != "200" ]]; then
    echo "manifest HEAD returned HTTP ${status}"
    return 1
  fi
  echo "manifest found for ${repo_path}:${NIM_IMAGE_TAG}"
  return 0
}

# 4. Chart fetch: helm can read the nim-llm chart at the pinned version, key
# fed via stdin, never as an argv value.
check_chart_fetch() {
  if [[ -z "${NGC_API_KEY:-}" ]]; then
    echo "skipped: NGC_API_KEY unset"
    return 1
  fi
  local out
  out="$(ngc_curl -fsS -r 0-0 -o /dev/null "${NIM_CHART_URL}" 2>&1)" || {
    echo "chart fetch failed: ${out}"
    return 1
  }
  echo "chart nim-llm-${NIM_CHART_VERSION} readable"
  return 0
}

# 5. L4 quota in the region: NVIDIA_L4_GPUS limit minus usage >= GPU_COUNT.
check_l4_quota() {
  local json
  json="$(gcloud compute regions describe "${REGION}" --project="${PROJECT_ID}" --format=json 2>&1)" || {
    echo "gcloud compute regions describe failed: ${json}"
    return 1
  }
  python3 - "${json}" "${GPU_COUNT}" <<'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
need = float(sys.argv[2])
quotas = {q["metric"]: q for q in data.get("quotas", [])}
q = quotas.get("NVIDIA_L4_GPUS")
if q is None:
    print("NVIDIA_L4_GPUS quota not found in region", file=sys.stderr)
    sys.exit(1)
available = q["limit"] - q["usage"]
if available < need:
    print(f"available {available} < needed {need} (limit {q['limit']}, usage {q['usage']})", file=sys.stderr)
    sys.exit(1)
print(f"available {available} >= needed {need} (limit {q['limit']}, usage {q['usage']})")
PYEOF
}

# 6. No existing cluster with CLUSTER_NAME.
check_no_cluster() {
  local existing
  existing="$(gcloud container clusters list --project="${PROJECT_ID}" \
    --filter="name=${CLUSTER_NAME}" --format='value(name)' 2>&1)" || {
    echo "gcloud container clusters list failed: ${existing}"
    return 1
  }
  if [[ -n "${existing}" ]]; then
    echo "cluster ${CLUSTER_NAME} already exists"
    return 1
  fi
  echo "no cluster named ${CLUSTER_NAME}"
  return 0
}

check "NGC_API_KEY set" check_ngc_key
check "gcloud active account" check_gcloud_auth
check "image tag exists (nvcr.io)" check_image_tag
check "chart fetch (helm.ngc.nvidia.com)" check_chart_fetch
check "L4 quota in ${REGION}" check_l4_quota
check "no existing cluster ${CLUSTER_NAME}" check_no_cluster

if [[ "${FAIL}" -ne 0 ]]; then
  echo "PREFLIGHT: FAIL"
  exit 1
fi
echo "PREFLIGHT: PASS"
