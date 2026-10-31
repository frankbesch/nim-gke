#!/bin/bash
# Tests for API_ALLOWED_CIDR: deploy_nim_gke.sh and deploy_nim_production.sh
# must refuse a missing, malformed, /0, or too-wide CIDR before any gcloud
# call, and deploy_nim_gke.sh must pass a valid one to clusters create as
# master authorized networks. Uses tests/stubs/ on PATH. No network.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="${REPO_ROOT}/scripts/deploy_nim_gke.sh"
PRODUCTION="${REPO_ROOT}/scripts/deploy_nim_production.sh"
STUB_DIR="${REPO_ROOT}/tests/stubs"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

export STUB_LOG="${TMP_DIR}/calls.log"
export PATH="${STUB_DIR}:${PATH}"
export PROJECT_ID="test-project"
export NGC_API_KEY="test-key"

FAIL=0

# --- C1: a valid CIDR reaches clusters create as an authorized network ---
: > "${STUB_LOG}"
set +e
c1_out="$(STUB_CLUSTER=absent STUB_NODEPOOL=absent API_ALLOWED_CIDR=203.0.113.10/32 "${DEPLOY}" 2>&1)"
c1_status=$?
set -e
create_line="$(grep "container clusters create" "${STUB_LOG}" || true)"
if [[ "${c1_status}" -eq 0 ]] \
  && echo "${create_line}" | grep -q -- "--enable-master-authorized-networks" \
  && echo "${create_line}" | grep -q -- "--master-authorized-networks=203.0.113.10/32"; then
  echo "C1 PASS"
else
  echo "C1 FAIL (status=${c1_status})"
  echo "--- clusters create line ---"; echo "${create_line}"
  echo "--- output ---"; echo "${c1_out}"
  FAIL=1
fi

# --- C2/C3: each bad CIDR is refused with no gcloud call, in both scripts ---
for script in "${DEPLOY}" "${PRODUCTION}"; do
  name="$(basename "${script}")"
  for cidr in "" "0.0.0.0/0" "203.0.113.10/0" "0.0.0.0/1" "10.0.0.0/8" "203.0.0.0/15" \
              "256.1.2.3/32" "01.2.3.4/32" "203.0.113.10/33" "203.0.113.10" "::/0"; do
    : > "${STUB_LOG}"
    set +e
    out="$(STUB_CLUSTER=absent API_ALLOWED_CIDR="${cidr}" "${script}" 2>&1)"
    status=$?
    set -e
    if [[ "${status}" -ne 0 ]] && ! grep -q "^gcloud" "${STUB_LOG}"; then
      echo "PASS ${name} refuses '${cidr}'"
    else
      echo "FAIL ${name} accepted '${cidr}' or called gcloud (status=${status})"
      grep "^gcloud" "${STUB_LOG}" | head -3
      echo "${out}" | tail -3
      FAIL=1
    fi
  done
done

# --- C4: the production path also passes the CIDR to clusters create ---
if grep -q -- '--master-authorized-networks="${API_ALLOWED_CIDR}"' "${PRODUCTION}"; then
  echo "C4 PASS"
else
  echo "C4 FAIL: deploy_nim_production.sh does not set master authorized networks"
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi

exit 0
