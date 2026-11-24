#!/usr/bin/env bash
# Health check script for Nimbus ETH1 Benchmark
# Usage: health-check.sh [benchmark_type]
# Consul script check exit codes: 0 = passing, 1 = warning, 2 = critical
#
# Runs are started from GitHub Actions and the host is idle in between, so this
# looks at the result of the last run and at a run that is taking too long.
# A failed run raises its own Discord alert, see run-state.sh.
set -e

METRICS_FILE="${METRICS_FILE:-/var/lib/nimbus-benchmark-metrics/benchmark_metrics.yaml}"
BENCHMARK_TYPE="${1:-${BENCHMARK_TYPE:-short}}"
BENCHMARK_ENV_FILE="${BENCHMARK_ENV_FILE:-/data/scripts/benchmark.env}"

if [[ -r "${BENCHMARK_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${BENCHMARK_ENV_FILE}"
fi

unhealthy() {
    echo "UNHEALTHY: $1"
    exit 2
}

healthy() {
    echo "HEALTHY: $1"
    exit 0
}

benchmarkRunning() {
    systemctl is-active --quiet "${BENCHMARK_SERVICE_NAME}.service"
}

# Max duration of a run depends on benchmark type
if [[ "${BENCHMARK_TYPE}" == "short" ]]; then
    MAX_AGE_SECONDS=36000   # 10 hours
else
    MAX_AGE_SECONDS=396000  # 110 hours
fi

LAST_RUN=$(grep "^last_run_timestamp:" "${METRICS_FILE}" 2>/dev/null | awk '{print $2}')
if [[ -z "${LAST_RUN}" || "${LAST_RUN}" == "0" ]]; then
    healthy "No ${BENCHMARK_TYPE} benchmark has been triggered yet"
fi

# Extract git hash for error reporting
GIT_HASH=$(grep -A1 "^metadata:" "${METRICS_FILE}" | grep "git_hash:" | awk -F'"' '{print $2}')
GIT_HASH="${GIT_HASH:-unknown}"
COMMIT_REF="${GIT_HASH}"
if [[ "${GIT_HASH}" != "unknown" && -n "${NIMBUS_ETH1_REPO_URL:-}" ]]; then
    COMMIT_REF="<${NIMBUS_ETH1_REPO_URL%.git}/commit/${GIT_HASH}>"
fi

# Check for any failed stages (success: 0)
if grep -q "success: 0" "${METRICS_FILE}"; then
    FAILED_STAGES=$(grep -B1 "success: 0" "${METRICS_FILE}" | grep -E "^  [a-zA-Z]" | tr -d ' :' | paste -sd ',' - | sed 's/,/, /g')
    unhealthy "Failed stages: ${FAILED_STAGES} (nimbus-eth1 commit: ${COMMIT_REF})"
fi

# The timestamp is taken when a run starts, its age only matters while that run is going
HOURS_AGO=$(( ($(date +%s) - LAST_RUN) / 3600 ))
MAX_HOURS=$((MAX_AGE_SECONDS / 3600))

if [[ ${HOURS_AGO} -ge ${MAX_HOURS} ]] && benchmarkRunning; then
    unhealthy "${BENCHMARK_TYPE} benchmark has been running for ${HOURS_AGO}h, exceeds ${MAX_HOURS}h threshold (nimbus-eth1 commit: ${COMMIT_REF})"
fi

healthy "Last ${BENCHMARK_TYPE} benchmark started ${HOURS_AGO}h ago, all stages succeeded (nimbus-eth1 commit: ${COMMIT_REF})"
