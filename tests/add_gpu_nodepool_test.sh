#!/bin/bash
# scripts/add_gpu_nodepool.sh confirmation gate, stubs only (no network):
#   P1 existing pool, no terminal, no flag -> exit 1, no delete call.
#   P2 existing pool, --yes -> delete and create calls logged.
#   P3 unknown flag -> exit 2.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/add_gpu_nodepool.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
export STUB_LOG="${TMP_DIR}/calls.log" PATH="${REPO_ROOT}/tests/stubs:${PATH}"
export PROJECT_ID=test-project STUB_NODEPOOL=present
FAIL=0

: > "${STUB_LOG}"; set +e; bash "${SCRIPT}" </dev/null >/dev/null 2>&1; s=$?; set -e
if [[ "${s}" -eq 1 ]] && ! grep -q "node-pools delete" "${STUB_LOG}"; then echo "P1 PASS"; else echo "P1 FAIL (status=${s})"; FAIL=1; fi

: > "${STUB_LOG}"; set +e; bash "${SCRIPT}" --yes </dev/null >/dev/null 2>&1; s=$?; set -e
if grep -q "node-pools delete gpupool" "${STUB_LOG}" && grep -q "node-pools create gpupool" "${STUB_LOG}"; then echo "P2 PASS"; else echo "P2 FAIL (status=${s})"; cat "${STUB_LOG}"; FAIL=1; fi

set +e; bash "${SCRIPT}" --bogus </dev/null >/dev/null 2>&1; s=$?; set -e
if [[ "${s}" -eq 2 ]]; then echo "P3 PASS"; else echo "P3 FAIL (status=${s})"; FAIL=1; fi

exit "${FAIL}"
