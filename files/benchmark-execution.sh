#!/usr/bin/env bash
# vim: ft=sh
set -e

function startNimbusWithImport() {
  # unique run directory for systemd service
  mkdir -p "${CURRENT_BENCHMARK_RUN_DIR}"

  local args=(
    --network='mainnet'
    --data-dir="${NIMBUS_ETH1_DB_DIR}"
    --era1-dir="${ERA1_DIR}"
    --era-dir="${ERA_DIR}"
    --log-level='INFO'
    --debug-rewrite-datadir-id=true
    --debug-csv-stats="${DEBUG_CSV_PATH}"
  )

  if [[ "${BENCHMARKING_TYPE}" == "short" ]]; then
    args+=(--max-blocks=${MAX_BLOCKS_TO_IMPORT})
  fi

  "${NIMBUS_ETH1_REPO}"/build/nimbus_execution_client import "${args[@]}"
}

function skipOrContinueBenchmark() {
  local NIMBUS_ETH1_GIT_HASH=$(cd "${NIMBUS_ETH1_REPO}" && git rev-parse --short=8 HEAD)
  local BENCHMARK_EXISTS=$(find "${NIMBUS_ETH1_BENCHMARKS_REPO}" -type d -name '*'"${NIMBUS_ETH1_GIT_HASH}"'*' 2>/dev/null | wc -l)

  if [ "${BENCHMARK_EXISTS}" -gt 0 ] && [ "${FORCE_RUN}" != "true" ]; then
    echo ">>> Benchmark for ${NIMBUS_ETH1_GIT_HASH} already exists, skipping this import!"
    exit 1
  fi
}
