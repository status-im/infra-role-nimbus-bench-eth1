#!/usr/bin/env bash
# vim: ft=sh
set -e

RUN_ID=""
RUN_URL=""
RUN_STAGE=""
RUN_SKIPPED="false"
RUN_TERMINATED="false"
RUN_LOG_PID=""

function runStateFile() {
  echo "${BENCHMARK_TRIGGER_DIR}/runs/${RUN_ID}.$1"
}

# The request is written by the runner user, which is not trusted with the keys of
# this user. It is parsed strictly instead of sourced, and a rejected value is never
# printed because the log of the run is public.
function loadTriggerParams() {
  local params_file="${BENCHMARK_TRIGGER_DIR}/requests/params.env"
  local max_age_seconds=300
  local key value line_number=0 valid="true"

  RUN_ID="manual-${SYSTEMD_INVOCATION_ID:-$(date +%s)}"

  if [[ ! -f "${params_file}" || -L "${params_file}" ]]; then
    echo ">>> No trigger request found, running with defaults"
    return 0
  fi

  # a request left behind by an earlier job must not leak into a manual start
  if (( $(date +%s) - $(stat -c %Y "${params_file}") > max_age_seconds )); then
    echo ">>> Ignoring stale trigger request, running with defaults"
    return 0
  fi

  while IFS='=' read -r key value || [[ -n "${key}" ]]; do
    line_number=$((line_number + 1))
    valid="false"
    case "${key}" in
      RUN_ID)
        [[ "${value}" =~ ^[0-9]+-[0-9]+$ ]] || break
        RUN_ID="${value}" ;;
      RUN_URL)
        [[ "${value}" =~ ^(https://github\.com/[A-Za-z0-9._/-]+/actions/runs/[0-9]+)?$ ]] || break
        RUN_URL="${value}" ;;
      REQUESTED_COMMIT)
        [[ "${value}" =~ ^([0-9a-f]{7,40})?$ ]] || break
        REQUESTED_COMMIT="${value}" ;;
      FORCE_RUN)
        [[ "${value}" =~ ^(true|false)$ ]] || break
        FORCE_RUN="${value}" ;;
      *)
        break ;;
    esac
    valid="true"
  done < "${params_file}"

  if [[ "${valid}" != "true" ]]; then
    echo ">>> Invalid trigger request on line ${line_number}, refusing to run"
    return 1
  fi

  export REQUESTED_COMMIT FORCE_RUN
}

# Mirrors the output of the run into a file the triggering job can follow.
function startRunLog() {
  local runs_dir="${BENCHMARK_TRIGGER_DIR}/runs"

  mkdir -p "${runs_dir}"
  find "${runs_dir}" -type f -mtime +30 -delete 2>/dev/null || true

  # tee has to outlive a stop of the service to capture the last lines of the run
  exec > >(trap '' TERM INT; exec tee -a "$(runStateFile log)") 2>&1
  RUN_LOG_PID=$!
}

function writeRunStatus() {
  local result="$1"
  local status_file
  status_file="$(runStateFile status)"

  {
    echo "result=${result}"
    echo "stage=${RUN_STAGE}"
    echo "commit=${GIT_HASH:-}"
  } > "${status_file}.tmp"
  mv "${status_file}.tmp" "${status_file}"
}

function writeRunSummary() {
  local result="$1"
  local repo_url="${NIMBUS_ETH1_REPO_URL%.git}"
  local results_url="${BENCHMARKS_REPO_URL%.git}"
  results_url="https://github.com/${results_url#*github.com[:/]}"

  echo "### ${BENCHMARKING_TYPE} benchmark: ${result}"
  echo
  echo "| | |"
  echo "|---|---|"
  if [[ -n "${GIT_HASH:-}" ]]; then
    echo "| nimbus-eth1 commit | [${GIT_HASH}](${repo_url}/commit/${GIT_HASH}) |"
  fi

  case "${result}" in
    failed)
      echo "| Failed stage | \`${RUN_STAGE}\` |" ;;
    skipped)
      echo "| Reason | results for this commit already exist, trigger with \`force\` to run it again |" ;;
    success)
      local total_ns history_row
      total_ns=$(awk -F',' 'NR>1 {sum += $6} END {print sum}' "${DEBUG_CSV_PATH}")
      echo "| Import time | $(convertToHumanReadableTime "${total_ns}") |"
      echo "| Blocks | ${START_BLOCK} to ${END_BLOCK} (${TOTAL_BLOCKS}) |"

      # the history is rebuilt on publish, its newest row for this commit holds the comparison
      history_row=$(awk -F',' -v commit="${GIT_HASH}" '$3 == commit {print; exit}' \
        "${NIMBUS_ETH1_BENCHMARKS_REPO}/${BENCHMARKING_TYPE}-benchmark-history.csv" 2>/dev/null)
      if [[ -n "${history_row}" ]]; then
        echo "${history_row}" | awk -F',' -v url="${repo_url}/commit" '{
          gsub(/"/, "", $6); gsub(/"/, "", $7)
          printf "| Baseline | [%s](%s/%s), %s |\n", $2, url, $2, $4
          printf "| Change against baseline | %s,%s |\n", $6, $7
        }'
      fi
      echo "| Results | [$(basename "${BENCHMARK_DESTINATION}")](${results_url}/tree/master/${BENCHMARKING_TYPE}-benchmark/$(basename "${BENCHMARK_DESTINATION}")) |" ;;
  esac
}

# Runs when the script exits for any reason, the exit code of the run is kept.
function finishRun() {
  local exit_code="$1"
  local result="success"

  set +e
  # the log pipe may be gone already, losing a line must not kill the bookkeeping
  trap '' PIPE

  if [[ "${RUN_SKIPPED}" == "true" ]]; then
    result="skipped"
  elif [[ "${RUN_TERMINATED}" == "true" ]]; then
    result="cancelled"
  elif [[ ${exit_code} -ne 0 ]]; then
    result="failed"
  fi

  writeRunStatus "${result}"
  writeRunSummary "${result}" > "$(runStateFile summary.md)"

  # a cancelled run is somebody's decision, only real failures raise an alert
  if [[ "${result}" == "failed" ]]; then
    sendDiscordAlert "${BENCHMARKING_TYPE}" \
      "Failed stage: ${RUN_STAGE} (nimbus-eth1 commit: ${GIT_HASH:-unknown}) ${RUN_URL}"
  fi

  # let tee drain before systemd tears the service down, but do not hang
  # on it if some leftover process still holds the other end of the pipe
  exec >&- 2>&-
  local waited=0
  while kill -0 "${RUN_LOG_PID}" 2>/dev/null && (( waited < 50 )); do
    sleep 0.2
    waited=$((waited + 1))
  done
}

function initRun() {
  local secrets_file="${SCRIPT_DIR}/benchmark-secrets.env"

  if [[ -r "${secrets_file}" ]]; then
    # shellcheck disable=SC1090
    source "${secrets_file}"
  fi

  loadTriggerParams
  startRunLog
  trap 'finishRun $?' EXIT
  trap 'RUN_TERMINATED="true"; exit 143' TERM INT

  echo ">>> Run ${RUN_ID} ${RUN_URL}"
}
