#!/bin/bash
# Test for scripts/preflight.sh's AUTOSCALE=1 quota gate (check 7). Never
# calls real gcloud/curl; uses a dedicated stub dir (gcloud, curl) on PATH.
# No network.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="${REPO_ROOT}/scripts/preflight.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_DIR="${TMP_DIR}/fakes"
mkdir -p "${FAKE_DIR}"

# gcloud: active account; NVIDIA_L4_GPUS limit 1 usage 0 in the region;
# GPUS_ALL_REGIONS limit 100 usage 0 in the project (not the limiting
# factor, so the failure below is attributable to NVIDIA_L4_GPUS); no
# existing cluster.
cat > "${FAKE_DIR}/gcloud" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$1 $2" in
  "auth list")
    echo "tester@example.com"
    exit 0
    ;;
  "compute project-info")
    cat <<'JSON'
{"quotas": [{"metric": "GPUS_ALL_REGIONS", "limit": 100, "usage": 0}]}
JSON
    exit 0
    ;;
  "compute regions")
    cat <<'JSON'
{"quotas": [{"metric": "NVIDIA_L4_GPUS", "limit": 1, "usage": 0}]}
JSON
    exit 0
    ;;
esac
case "$1 $2 $3" in
  "container clusters list")
    exit 0
    ;;
esac
exit 0
EOF

# curl: never reached for a real registry; just refuse (still no network,
# since this is a local stub either way).
cat > "${FAKE_DIR}/curl" <<'EOF'
#!/bin/bash
exit 1
EOF

chmod +x "${FAKE_DIR}"/gcloud "${FAKE_DIR}"/curl

export PATH="${FAKE_DIR}:${PATH}"
export PROJECT_ID="test-project"
export NGC_API_KEY="test-key"
export AUTOSCALE=1
export MAX_GPU_NODES=2   # needs 2 L4s; stub region quota only has 1 available

FAIL=0

set +e
a6_out="$("${PREFLIGHT}" 2>&1)"
a6_status=$?
set -e

a6_pass=true
[[ "${a6_status}" -ne 0 ]] || a6_pass=false
if ! echo "${a6_out}" | grep -Eq "GPUS_ALL_REGIONS|NVIDIA_L4_GPUS"; then
  a6_pass=false
fi
if ! echo "${a6_out}" | grep -q "limit 1"; then
  a6_pass=false
fi
if ! echo "${a6_out}" | grep -q "needed 2"; then
  a6_pass=false
fi

if [[ "${a6_pass}" == "true" ]]; then
  echo "A6 PASS"
else
  echo "A6 FAIL (status=${a6_status})"
  echo "--- output ---"; echo "${a6_out}"
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi

exit 0
