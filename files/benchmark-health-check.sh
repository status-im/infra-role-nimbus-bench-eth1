#!/usr/bin/env bash
# Health check script for Nimbus ETH1 Benchmark
# Usage: health-check.sh [benchmark_type]
# Consul script check exit codes: 0 = passing, 1 = warning, 2 = critical
set -e

METRICS_FILE="${METRICS_FILE:-/var/lib/nimbus-benchmark-metrics/benchmark_metrics.yaml}"
BENCHMARK_TYPE="${1:-${BENCHMARK_TYPE:-short}}"

# Max age depends on benchmark type
if [[ "${BENCHMARK_TYPE}" == "short" ]]; then
    MAX_AGE_SECONDS=36000   # 10 hours
else
    MAX_AGE_SECONDS=396000  # 110 hours
fi

# Check if metrics file exists
if [[ ! -f "${METRICS_FILE}" ]]; then
    echo "UNHEALTHY: Metrics file not found: ${METRICS_FILE}"
    exit 2
fi

# Extract git hash for error reporting
GIT_HASH=$(grep -A1 "^metadata:" "${METRICS_FILE}" | grep "git_hash:" | awk -F'"' '{print $2}')
GIT_HASH="${GIT_HASH:-unknown}"

# Check for any failed stages (success: 0)
if grep -q "success: 0" "${METRICS_FILE}"; then
    FAILED_STAGES=$(grep -B1 "success: 0" "${METRICS_FILE}" | grep -E "^  [a-zA-Z]" | tr -d ':' | tr '\n' ', ' | sed 's/, $//')
    echo "UNHEALTHY: Failed stages: ${FAILED_STAGES} (nimbus-eth1 commit: ${GIT_HASH})"
    exit 2
fi

# Check if benchmark is stale
LAST_RUN=$(grep "^last_run_timestamp:" "${METRICS_FILE}" | awk '{print $2}')
if [[ -z "${LAST_RUN}" || "${LAST_RUN}" == "0" ]]; then
    echo "UNHEALTHY: No benchmark has completed yet (nimbus-eth1 commit: ${GIT_HASH})"
    exit 2
fi

CURRENT_TIME=$(date +%s)
AGE=$((CURRENT_TIME - LAST_RUN))

if [[ ${AGE} -gt ${MAX_AGE_SECONDS} ]]; then
    HOURS_AGO=$((AGE / 3600))
    MAX_HOURS=$((MAX_AGE_SECONDS / 3600))
    echo "UNHEALTHY: Last ${BENCHMARK_TYPE} benchmark was ${HOURS_AGO}h ago, exceeds ${MAX_HOURS}h threshold (nimbus-eth1 commit: ${GIT_HASH})"
    exit 2
fi

# All checks passed
HOURS_AGO=$((AGE / 3600))
echo "HEALTHY: Last ${BENCHMARK_TYPE} benchmark ${HOURS_AGO}h ago, all stages succeeded (nimbus-eth1 commit: ${GIT_HASH})"
exit 0
