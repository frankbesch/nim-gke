#!/bin/bash
# Tests for scripts/deploy_nim_gke.sh AUTOSCALE=1 vs AUTOSCALE=0 node-pool
# creation flags. Never calls real gcloud/kubectl/helm/curl; uses
# tests/stubs/ (gcloud, kubectl, helm, curl) on PATH. No network.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="${REPO_ROOT}/scripts/deploy_nim_gke.sh"
STUB_DIR="${REPO_ROOT}/tests/stubs"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

export STUB_LOG="${TMP_DIR}/calls.log"
export PATH="${STUB_DIR}:${PATH}"
export PROJECT_ID="test-project"
export NGC_API_KEY="test-key"
export STUB_CLUSTER=present   # skip cluster creation; this test is about gpupool
export STUB_NODEPOOL=absent   # force the node-pools create branch

FAIL=0

# --- A1: AUTOSCALE=1 -> gpupool created with 0 nodes + autoscaling flags ---
: > "${STUB_LOG}"
set +e
a1_out="$(AUTOSCALE=1 "${DEPLOY}" 2>&1)"
a1_status=$?
set -e

a1_pass=true
[[ "${a1_status}" -eq 0 ]] || a1_pass=false
np_line="$(grep "node-pools create gpupool" "${STUB_LOG}" || true)"
[[ -n "${np_line}" ]] || a1_pass=false
if ! echo "${np_line}" | grep -q -- "--num-nodes=0"; then a1_pass=false; fi
if ! echo "${np_line}" | grep -q -- "--enable-autoscaling"; then a1_pass=false; fi
if ! echo "${np_line}" | grep -q -- "--min-nodes=0"; then a1_pass=false; fi
if ! echo "${np_line}" | grep -q -- "--max-nodes=1"; then a1_pass=false; fi

if [[ "${a1_pass}" == "true" ]]; then
  echo "A1 PASS"
else
  echo "A1 FAIL (status=${a1_status})"
  echo "--- node-pools create line ---"; echo "${np_line}"
  echo "--- output ---"; echo "${a1_out}"
  FAIL=1
fi

# --- A2: AUTOSCALE=0 (default) -> gpupool created with --num-nodes=1, no autoscaling ---
: > "${STUB_LOG}"
set +e
a2_out="$(env -u AUTOSCALE "${DEPLOY}" 2>&1)"
a2_status=$?
set -e

a2_pass=true
[[ "${a2_status}" -eq 0 ]] || a2_pass=false
np_line2="$(grep "node-pools create gpupool" "${STUB_LOG}" || true)"
[[ -n "${np_line2}" ]] || a2_pass=false
if ! echo "${np_line2}" | grep -q -- "--num-nodes=1"; then a2_pass=false; fi
if echo "${np_line2}" | grep -q -- "--enable-autoscaling"; then a2_pass=false; fi
if echo "${np_line2}" | grep -q -- "--min-nodes"; then a2_pass=false; fi
if echo "${np_line2}" | grep -q -- "--max-nodes"; then a2_pass=false; fi

if [[ "${a2_pass}" == "true" ]]; then
  echo "A2 PASS"
else
  echo "A2 FAIL (status=${a2_status})"
  echo "--- node-pools create line ---"; echo "${np_line2}"
  echo "--- output ---"; echo "${a2_out}"
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi

exit 0
