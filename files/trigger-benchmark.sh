#!/usr/bin/env bash
# vim: ft=sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/benchmark.env"

SERVICE="${BENCHMARK_SERVICE_NAME}.service"
REQUESTS_DIR="${BENCHMARK_TRIGGER_DIR}/requests"
RUNS_DIR="${BENCHMARK_TRIGGER_DIR}/runs"
PARAMS_FILE="${REQUESTS_DIR}/params.env"
STARTED_FILE="${REQUESTS_DIR}/started"
RUN_ID="${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-1}"
TAIL_PID=""

function fail() {
  echo "::error::$1"
  exit 1
}

function benchmarkBusy() {
  case "$(systemctl is-active "${SERVICE}" || true)" in
    active|activating|deactivating|reloading) return 0 ;;
    *) return 1 ;;
  esac
}

function readStatus() {
  grep -m 1 "^$1=" "${RUNS_DIR}/${RUN_ID}.status" 2>/dev/null | cut -d= -f2- || true
}

function stopLogMirror() {
  if [[ -n "${TAIL_PID}" ]]; then
    kill "${TAIL_PID}" 2>/dev/null || true
    TAIL_PID=""
  fi
}

# Stops the benchmark this job started. A job that runs into its time limit is cut off
# the same way as a cancelled one, in that case the benchmark is left running so it can
# still finish and publish, only the job is lost.
function stopBenchmark() {
  local started_run started_at limit_seconds

  [[ -r "${STARTED_FILE}" ]] || return 0
  read -r started_run started_at < "${STARTED_FILE}"
  [[ "${started_run}" == "${RUN_ID}" ]] || return 0
  benchmarkBusy || return 0

  limit_seconds=$(( ${BENCHMARK_TIMEOUT_MINUTES:-0} * 60 ))
  if (( limit_seconds > 0 && $(date +%s) - started_at >= limit_seconds - 300 )); then
    echo "::warning::Job time limit reached, the benchmark keeps running and will publish its results"
    return 0
  fi

  echo ">>> Stopping ${SERVICE}"
  sudo -n /usr/bin/systemctl stop --no-block "${SERVICE}"
}

function runBenchmark() {
  local commit="${BENCHMARK_COMMIT:-}"
  local force="${BENCHMARK_FORCE:-false}"
  local run_url=""

  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  fi

  [[ "${BENCHMARK_TYPE:-}" == "${BENCHMARKING_TYPE}" ]] \
    || fail "This host runs the ${BENCHMARKING_TYPE} benchmark, not '${BENCHMARK_TYPE:-}'"
  [[ "${commit}" =~ ^([0-9a-f]{7,40})?$ ]] \
    || fail "commit has to be a hexadecimal commit hash of 7 to 40 characters"
  [[ "${force}" =~ ^(true|false)$ ]] \
    || fail "force has to be true or false"
  if benchmarkBusy; then
    fail "${SERVICE} is already running, wait for it to finish or stop it on the host"
  fi

  umask 022
  {
    echo "RUN_ID=${RUN_ID}"
    echo "RUN_URL=${run_url}"
    echo "REQUESTED_COMMIT=${commit}"
    echo "FORCE_RUN=${force}"
  } > "${PARAMS_FILE}.tmp"
  mv "${PARAMS_FILE}.tmp" "${PARAMS_FILE}"
  echo "${RUN_ID} $(date +%s)" > "${STARTED_FILE}"

  trap stopLogMirror EXIT
  trap 'stopBenchmark; exit 130' INT TERM

  # --pid makes the mirror go away with this script even if it gets killed
  tail --pid=$$ -n +1 -F "${RUNS_DIR}/${RUN_ID}.log" 2>/dev/null &
  TAIL_PID=$!

  sudo -n /usr/bin/systemctl start "${SERVICE}"

  # sleep in the background so a cancellation is handled right away
  while benchmarkBusy; do
    sleep 5 &
    wait $! || true
  done

  # give the mirror a moment to print the last lines
  sleep 2
  stopLogMirror

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -f "${RUNS_DIR}/${RUN_ID}.summary.md" ]]; then
    cat "${RUNS_DIR}/${RUN_ID}.summary.md" >> "${GITHUB_STEP_SUMMARY}"
  fi

  case "$(readStatus result)" in
    success)
      echo ">>> Benchmark finished for commit $(readStatus commit)" ;;
    skipped)
      echo "::notice title=Benchmark skipped::Results for commit $(readStatus commit) already exist, trigger with force to run it again" ;;
    cancelled)
      fail "Benchmark was stopped before it finished" ;;
    failed)
      fail "Benchmark failed in stage $(readStatus stage)" ;;
    *)
      fail "Benchmark ended without reporting a status, systemd result: $(systemctl show --value -p Result "${SERVICE}")" ;;
  esac
}

case "${1:-}" in
  run)
    runBenchmark ;;
  cleanup)
    stopBenchmark ;;
  *)
    echo "Usage: $0 run|cleanup"
    exit 1 ;;
esac
