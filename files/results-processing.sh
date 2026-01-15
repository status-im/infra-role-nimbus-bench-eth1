#!/usr/bin/env bash
# vim: ft=sh
set -e

# Find the previous benchmarked commit using git history
# This ensures correct comparison even when benchmarks are run out of order
# Args:
#   $1 - current commit hash (short or full)
#   $2 - benchmark type directory path
# Returns: the benchmark directory name (YYYYMMDDTHHMMSS_hash) of the previous benchmark
function findPreviousBenchmarkByGitHistory() {
  local CURRENT_COMMIT="$1"
  local BENCHMARK_TYPE_DIR="$2"

  if [ ! -d "${BENCHMARK_TYPE_DIR}" ]; then
    return
  fi

  # Get list of all benchmarked commit hashes (8 char)
  local BENCHMARKED_COMMITS=$(find "${BENCHMARK_TYPE_DIR}" -mindepth 1 -maxdepth 1 -type d -name '*_*' \
    ! -name 'latest' -exec basename {} \; | sed 's/.*_//' | sort -u)

  if [ -z "${BENCHMARKED_COMMITS}" ]; then
    return
  fi

  cd "${NIMBUS_ETH1_REPO}"

  # Get full hash for current commit
  local CURRENT_FULL=$(git rev-parse "${CURRENT_COMMIT}" 2>/dev/null || echo "${CURRENT_COMMIT}")

  # Get ancestors of current commit (excluding itself), newest first
  local ANCESTORS=$(git rev-list "${CURRENT_FULL}^" 2>/dev/null || true)

  if [ -z "${ANCESTORS}" ]; then
    return
  fi

  # Find the first ancestor that has a benchmark
  for ancestor in ${ANCESTORS}; do
    local short_ancestor=$(echo "${ancestor}" | cut -c1-8)
    if echo "${BENCHMARKED_COMMITS}" | grep -q "^${short_ancestor}"; then
      # Found it - now get the full directory name
      local DIR_NAME=$(find "${BENCHMARK_TYPE_DIR}" -mindepth 1 -maxdepth 1 -type d -name "*_${short_ancestor}*" \
        ! -name 'latest' -exec basename {} \; 2>/dev/null | head -n 1)
      if [ -n "${DIR_NAME}" ]; then
        echo "${DIR_NAME}"
        return
      fi
    fi
  done
}

function convertToHumanReadableTime() {
  local total_ns=$1

  # Convert to seconds with decimal precision
  local total_seconds=$(awk "BEGIN {printf \"%.2f\", $total_ns/1000000000}")

  # Convert to integer seconds for calculations
  local seconds_int=${total_seconds%.*}
  local days=$((seconds_int / 86400))
  local hours=$(((seconds_int % 86400) / 3600))
  local minutes=$(((seconds_int % 3600) / 60))
  local seconds=$((seconds_int % 60))

  # For printing in human readable string
  local result=""
  [[ $days -gt 0 ]] && result+="$days days "
  [[ $hours -gt 0 ]] && result+="$hours hours "
  [[ $minutes -gt 0 ]] && result+="$minutes minutes "
  [[ $seconds -gt 0 ]] && result+="$seconds seconds"

  # Trim extra spaces and handle empty result
  result="${result%% }"
  [[ -z "$result" ]] && result="less than 1 second"

  echo "$result"
}

function fetchBenchmarkingJobSummary() {
  local total_time
  total_time=$(
    awk -F',' '
      NR>1 { # Skip header row
          sum += $6
      }
      END {
          print sum
      }' "$DEBUG_CSV_PATH"
  )

  if [ -z "$total_time" ]; then
    echo "Error: No time data found in csv or invalid input at $DEBUG_CSV_PATH"
    exit 1
  fi

  echo "=== Nimbus-ETH1 Benchmarking Report ==="
  echo ">>> Total time spent in benchmarking (nanoseconds): ${total_time}"
  echo ">>> Total time spent in benchmarking (human readable format): $(convertToHumanReadableTime "$total_time")"

  # start block number is column[0] - column[1]
  local START_BLOCK_NUMBER=$(tail -n +2 "${DEBUG_CSV_PATH}" | head -1 | awk -F',' '{print $1 - $2}')
  echo ">>> Start block number is ${START_BLOCK_NUMBER}"

  local END_BLOCK_NUMBER=$(tail -1 "${DEBUG_CSV_PATH}" | cut -d',' -f1)
  echo ">>> End block number is ${END_BLOCK_NUMBER}"

  echo "=========================="
}

function fetchHostInformation() {
  echo "=== System Information Report ==="
  echo ">>> Generated on: $(date)"
  echo "=========================="

  echo -n ">>> CPU Architecture: "
  lscpu | grep "Architecture" | awk '{print $2}'

  echo -n ">>> CPU Byte Order: "
  lscpu | grep "Byte Order" | sed 's/Byte Order://' | sed 's/^[ \t]*//'

  echo -n ">>> CPU Cores: "
  nproc

  echo -n ">>> CPU Model: "
  lscpu | grep "Model name" | sed 's/Model name://' | sed 's/^[ \t]*//'

  echo ">>> CPU Cache Information:"
  echo -n "L1d Cache: "
  lscpu | grep "L1d" | sed 's/L1d cache://' | sed 's/^[ \t]*//'
  echo -n "L1i Cache: "
  lscpu | grep "L1i" | sed 's/L1i cache://' | sed 's/^[ \t]*//'
  echo -n "L2 Cache: "
  lscpu | grep "L2" | sed 's/L2 cache://' | sed 's/^[ \t]*//'
  echo -n "L3 Cache: "
  lscpu | grep "L3" | sed 's/L3 cache://' | sed 's/^[ \t]*//'

  echo -n ">>> RAM Size: "
  free -h | grep "Mem:" | awk '{print $2}'

  echo ">>> Hard Disk Information:"
  df -h | grep '^/dev/' | awk '{print $1 " : " $2 " total, " $4 " free"}'
  echo "=========================="
}

function compareBenchmarkWithPrevious() {
  echo "=== Comparison with previous benchmark (by git history) ==="

  local NIMBUS_ETH1_BLOCKS_IMPORT_SCRIPT_PATH="${NIMBUS_ETH1_REPO}/scripts/block-import-stats.py"
  local VENV_PATH="${NIMBUS_ETH1_REPO}/stats"

  if [ ! -d "${CURRENT_BENCHMARK_TYPE_DIR}" ]; then
    echo "${CURRENT_BENCHMARK_TYPE_DIR} does not exist, skipping compareBenchmarkWithPrevious()"
    return
  fi

  # Get the current commit hash from the nimbus-eth1 repo
  local CURRENT_COMMIT=$(cd "${NIMBUS_ETH1_REPO}" && git rev-parse --short=8 HEAD)
  echo ">>> Current commit: ${CURRENT_COMMIT}"

  # Find the previous benchmark using git history (not file modification time)
  local PREVIOUS_BENCHMARK_DIR_NAME=$(findPreviousBenchmarkByGitHistory "${CURRENT_COMMIT}" "${CURRENT_BENCHMARK_TYPE_DIR}")

  if [ -z "${PREVIOUS_BENCHMARK_DIR_NAME}" ]; then
    echo "No previous benchmark found in git history, skipping comparison"
    return
  fi

  local PREVIOUS_COMMIT=$(echo "${PREVIOUS_BENCHMARK_DIR_NAME}" | sed 's/.*_//')
  echo ">>> Previous benchmark commit (by git history): ${PREVIOUS_COMMIT}"
  # Machine-readable line for regenerate_readme.sh to parse
  echo "BASELINE_COMMIT=${PREVIOUS_COMMIT}"
  echo "CONTENDER_COMMIT=${CURRENT_COMMIT}"

  # Current benchmark CSV - use the destination path since we're running during benchmark
  local CURRENT_BENCHMARK_CSV_PATH="${DEBUG_CSV_PATH}"
  local PREVIOUS_BENCHMARK_CSV_PATH="${CURRENT_BENCHMARK_TYPE_DIR}/${PREVIOUS_BENCHMARK_DIR_NAME}/${BENCHMARK_FILE_NAME}"

  if [ ! -f "${CURRENT_BENCHMARK_CSV_PATH}" ]; then
    echo "Current benchmark CSV not found at ${CURRENT_BENCHMARK_CSV_PATH}, skipping comparison"
    return
  fi

  if [ ! -f "${PREVIOUS_BENCHMARK_CSV_PATH}" ]; then
    echo "Previous benchmark CSV not found at ${PREVIOUS_BENCHMARK_CSV_PATH}, skipping comparison"
    return
  fi

  if [ ! -d "${VENV_PATH}" ]; then
    python -m venv "${VENV_PATH}"
  fi

  # Activate virtual environment
  source "${VENV_PATH}/bin/activate"

  if [ -f "${NIMBUS_ETH1_REPO}/scripts/requirements.txt" ]; then
    pip install -r "${NIMBUS_ETH1_REPO}/scripts/requirements.txt" >/dev/null 2>&1
  fi

  echo "python ${NIMBUS_ETH1_BLOCKS_IMPORT_SCRIPT_PATH} ${PREVIOUS_BENCHMARK_CSV_PATH} ${CURRENT_BENCHMARK_CSV_PATH}"
  python "${NIMBUS_ETH1_BLOCKS_IMPORT_SCRIPT_PATH}" "${PREVIOUS_BENCHMARK_CSV_PATH}" "${CURRENT_BENCHMARK_CSV_PATH}" 2>&1 || true

  # Deactivate virtual environment
  deactivate

  echo "=========================="
}

function generateSystemdServiceLogs() {
  # generate log file for previous run
   journalctl _SYSTEMD_INVOCATION_ID="${SYSTEMD_INVOCATION_ID}" -q --no-hostname \
      >> "${CURRENT_BENCHMARK_RUN_DIR}/nimbus-eth1-mainnet-master-${BENCHMARKING_TYPE}-benchmark-output.log"
}

function generateBuildEnvironmentLogFile() {

  {
    fetchHostInformation
    fetchBenchmarkingJobSummary
    compareBenchmarkWithPrevious
  } >>"${CURRENT_BENCHMARK_RUN_DIR}/build-environment.log" 2>&1
}

function moveBenchmarkingFileToRepo() {
  if [[ ! -f "${DEBUG_CSV_PATH}" ]]; then
    echo "${DEBUG_CSV_PATH} does not exist, skipping github publish stage"
    exit 1
  fi

  mkdir -p "${BENCHMARK_DESTINATION}"

  echo ">>> copying debug-csv generated by nimbus to benchmarks repo"
  cp "${DEBUG_CSV_PATH}" "${BENCHMARK_DESTINATION}/${BENCHMARK_FILE_NAME}"
}

function publishBenchmarkingResults() {
  cd "${NIMBUS_ETH1_BENCHMARKS_REPO}"
  # to debug git push failures
  export GIT_TRACE=1
  git fetch
  git add .
  git commit -m "${BENCHMARKING_TYPE}-benchmark: publish metrics and report"
  git pull --rebase -X ours
  git push

  echo ">>> Running regenerate_readme.sh to update repository README"
  "${NIMBUS_ETH1_BENCHMARKS_REPO}/regenerate_readme.sh"

  if git diff --quiet && git diff --cached --quiet; then
    echo "No changes detected after running regenerate_readme.sh, skipping README commit"
  else
    git add .
    git commit -m "chore: update ${BENCHMARKING_TYPE} benchmark Readme"
    git push
  fi
}

function moveFilesFromInvocationDirectoryToBenchmarkingRepo(){

  local LATEST_SYMLINK="${CURRENT_BENCHMARK_TYPE_DIR}/latest"

  cp -r "${CURRENT_BENCHMARK_RUN_DIR}"/* "${BENCHMARK_DESTINATION}"

  if [ -L "${LATEST_SYMLINK}" ]; then
    # gotta nuke existing symlink before we make a new one
    rm "${LATEST_SYMLINK}"
  fi

  local CURRENT_BENCHMARK_DIR_NAME=$(basename "${BENCHMARK_DESTINATION}")
  echo ">>> Creating symlink 'latest' pointing to current benchmark: ${CURRENT_BENCHMARK_DIR_NAME}"
  ln -sf "${CURRENT_BENCHMARK_DIR_NAME}" "${LATEST_SYMLINK}"

}
