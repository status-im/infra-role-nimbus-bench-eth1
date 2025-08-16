#!/usr/bin/env bash
# vim: ft=sh
set -e

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
  echo "=== Comparison of last two benchmarks ==="

  local NIMBUS_ETH1_BLOCKS_IMPORT_SCRIPT_PATH="${NIMBUS_ETH1_REPO}/scripts/block-import-stats.py"
  local VENV_PATH="${NIMBUS_ETH1_REPO}/stats"


  if [ ! -d "${CURRENT_BENCHMARK_TYPE_DIR}" ]; then
    echo "${CURRENT_BENCHMARK_TYPE_DIR} does not exist, skipping compareBenchmarkWithPrevious()"
    return
  fi

  if [[ ! "$(find "${CURRENT_BENCHMARK_TYPE_DIR}" -mindepth 1 -maxdepth 1 -type d | wc -l)" -gt 2 ]]; then
    echo "${CURRENT_BENCHMARK_TYPE_DIR} does not contain 2 or more benchmark CSVs, skipping compareBenchmarkWithPrevious()"
    return
  fi

  local CURRENT_BENCHMARK_DIR_NAME=$(find "${CURRENT_BENCHMARK_TYPE_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2)
  local PREVIOUS_BENCHMARK_DIR_NAME=$(find "${CURRENT_BENCHMARK_TYPE_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -nr | head -n 2 | tail -n 1 | cut -d' ' -f2)

  local CURRENT_BENCHMARK_CSV_PATH="${CURRENT_BENCHMARK_TYPE_DIR}/${CURRENT_BENCHMARK_DIR_NAME}/${BENCHMARK_FILE_NAME}"
  local PREVIOUS_BENCHMARK_CSV_PATH="${CURRENT_BENCHMARK_TYPE_DIR}/${PREVIOUS_BENCHMARK_DIR_NAME}/${BENCHMARK_FILE_NAME}"

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

function format_timestamp_date() {
  echo "$1" | awk '{
      year=substr($0,1,4)
      month=substr($0,5,2)
      day=substr($0,7,2)
      hour=substr($0,10,2)
      min=substr($0,12,2)
      sec=substr($0,14,2)
      print year "-" month "-" day " " hour ":" min ":" sec
  }'
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

function generateBenchmarkRepoReadme() {

  TABLE_HEADER="| Generated At | Baseline SHA | Contender SHA | Baseline Time | Contender Time | Time Delta |
|--------------|--------------|---------------|---------------|----------------|------------|"

  local LONG_BENCHMARK_TABLE="$TABLE_HEADER"
  local SHORT_BENCHMARK_TABLE="$TABLE_HEADER"

  while read -r file; do
      local raw_timestamp=$(echo "$file" | grep -o '[0-9]\{8\}T[0-9]\{6\}')
      local timestamp=$(format_timestamp_date "$raw_timestamp")

      local baseline_git_sha=$(grep "block-import-stats.py" "$file" | grep -o '[^/]*_[^/]*' | cut -d'_' -f2 | head -n 1)
      local contender_git_sha=$(grep "block-import-stats.py" "$file" | grep -o '[^/]*_[^/]*' | cut -d'_' -f2 | tail -n 1)

      # Extract baseline and contender times
      local baseline_time=$(grep -o "baseline: [0-9hms]*" "$file" | cut -d' ' -f2)
      local contender_time=$(grep -o "contender: [0-9hms]*" "$file" | cut -d' ' -f2)

      # Extract combined time delta and percentage
      local time_delta=$(grep "Time (total):" "$file" | sed 's/Time (total): \(.*\)/\1/')

      if [[ "$file" == *"short-benchmark"* ]]; then
          local benchmark_type="short"
      else
          local benchmark_type="long"
      fi

      # Remove any quotes if present
      local time_delta=$(echo "$time_delta" | tr -d '"')
      local baseline_time=$(echo "$baseline_time" | tr -d '"')
      local contender_time=$(echo "$contender_time" | tr -d '"')

      if [ ! -z "$baseline_git_sha" ] && [ ! -z "$contender_git_sha" ] && [ ! -z "$time_delta" ]; then
          local entry="| $timestamp | $baseline_git_sha | $contender_git_sha | $baseline_time | $contender_time | $time_delta |"
          if [[ "$benchmark_type" == "short" ]]; then
              SHORT_BENCHMARK_TABLE="${SHORT_BENCHMARK_TABLE}
$entry"
          else
              LONG_BENCHMARK_TABLE="${LONG_BENCHMARK_TABLE}
$entry"
          fi
      else
          echo "Warning: Could not extract all required data from $file" >&2
      fi
  done < <(find "${NIMBUS_ETH1_BENCHMARKS_REPO}" -name "build-environment.log" | sort -t'/' -k3 -r)

  export LONG_BENCHMARK_TABLE
  export SHORT_BENCHMARK_TABLE

  envsubst < "${README_TEMPLATE_PATH}" > "${README_FILE_PATH}"

  echo "Benchmarking History updated in ${README_FILE_PATH}"
}

function publishBenchmarkingResults() {
  cd "${NIMBUS_ETH1_BENCHMARKS_REPO}"
  # to debug git push failures
  export GIT_TRACE=1
  git fetch
  git add .
  git add "${README_FILE_PATH}"
  git commit -m "${BENCHMARKING_TYPE}-benchmark: publish metrics and report"
  git pull --rebase
  git push
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
