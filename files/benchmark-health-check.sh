#!/usr/bin/env bash
# Health check script for Nimbus ETH1 Benchmark
# Usage: health-check.sh [benchmark_type]
# Consul script check exit codes: 0 = passing, 1 = warning, 2 = critical
set -e

METRICS_FILE="${METRICS_FILE:-/var/lib/nimbus-benchmark-metrics/benchmark_metrics.yaml}"
BENCHMARK_TYPE="${1:-${BENCHMARK_TYPE:-short}}"
BENCHMARK_ENV_FILE="${BENCHMARK_ENV_FILE:-/data/scripts/benchmark.env}"
DISCORD_STATE_FILE="$(dirname "${METRICS_FILE}")/.discord_state_${BENCHMARK_TYPE}"

if [[ -r "${BENCHMARK_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${BENCHMARK_ENV_FILE}"
fi

notifyDiscord() {
    local message="$1"

    [[ -n "${DISCORD_WEBHOOK_URL:-}" ]] || return 0

    [[ -f "${DISCORD_STATE_FILE}" ]] && return 0

    date +%s >"${DISCORD_STATE_FILE}" 2>/dev/null \
      || echo "WARNING: cannot write ${DISCORD_STATE_FILE}"

    message="[critical] ${BENCHMARK_TYPE} benchmark on $(hostname -s): ${message}"
    [[ -n "${DISCORD_MENTION_ID:-}" ]] && message="<@${DISCORD_MENTION_ID}> ${message}"

    # discord caps message content at 2000 characters, truncate before escaping so
    # the cut cannot land in the middle of an escape sequence
    message="${message:0:1900}"
    message="${message//\\/\\\\}"
    message="${message//\"/\\\"}"
    message="${message//$'\n'/\\n}"

    printf '{"content":"%s","allowed_mentions":{"parse":["users"]}}' "${message}" \
      | curl -sS -X POST -H 'Content-Type: application/json' --max-time 15 \
             --data @- "${DISCORD_WEBHOOK_URL}" >/dev/null \
      || echo "WARNING: failed to deliver discord notification"

    return 0
}

unhealthy() {
    echo "UNHEALTHY: $1"
    notifyDiscord "$1"
    exit 2
}

# Max age depends on benchmark type
if [[ "${BENCHMARK_TYPE}" == "short" ]]; then
    MAX_AGE_SECONDS=36000   # 10 hours
else
    MAX_AGE_SECONDS=396000  # 110 hours
fi

# Check if metrics file exists
if [[ ! -f "${METRICS_FILE}" ]]; then
    unhealthy "Metrics file not found: ${METRICS_FILE}"
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

# Check if benchmark is stale
LAST_RUN=$(grep "^last_run_timestamp:" "${METRICS_FILE}" | awk '{print $2}')
if [[ -z "${LAST_RUN}" || "${LAST_RUN}" == "0" ]]; then
    unhealthy "No benchmark has completed yet (nimbus-eth1 commit: ${COMMIT_REF})"
fi

CURRENT_TIME=$(date +%s)
AGE=$((CURRENT_TIME - LAST_RUN))

if [[ ${AGE} -gt ${MAX_AGE_SECONDS} ]]; then
    HOURS_AGO=$((AGE / 3600))
    MAX_HOURS=$((MAX_AGE_SECONDS / 3600))
    unhealthy "Last ${BENCHMARK_TYPE} benchmark was ${HOURS_AGO}h ago, exceeds ${MAX_HOURS}h threshold (nimbus-eth1 commit: ${COMMIT_REF})"
fi

# All checks passed, clearing the marker so the next outage alerts again
rm -f "${DISCORD_STATE_FILE}" 2>/dev/null || true

HOURS_AGO=$((AGE / 3600))
echo "HEALTHY: Last ${BENCHMARK_TYPE} benchmark ${HOURS_AGO}h ago, all stages succeeded (nimbus-eth1 commit: ${COMMIT_REF})"
exit 0
