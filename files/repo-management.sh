#!/usr/bin/env bash
# vim: ft=sh
set -e

function cloneOrFetchRepo() {
  local repo_path="$1"
  local repo_url="$2"
  local branch="$3"
  local clean_repo="${4:-false}"

  mkdir -p "${repo_path}"
  chmod 775 "${repo_path}"

  if [ -d "${repo_path}/.git" ]; then
    cd "${repo_path}"
    if [ "${clean_repo}" = "true" ]; then
      git clean -fdx >/dev/null 2>&1
      git submodule foreach --recursive git clean -fdx >/dev/null 2>&1
    fi
    echo ">>> Fetching latest changes for $(basename "${repo_path}")..."
    git fetch
    git reset --hard "origin/${branch}"
  else
    echo ">>> Cloning $(basename "${repo_path}")..."
    git clone -b "${branch}" "${repo_url}" "${repo_path}"
    cd "${repo_path}"
  fi
}

function nextCommitToBenchmark() {
  local LAST_COMMIT="$1"

  # newest first, so the first line is head
  local NEW_COMMITS=$(git rev-list --first-parent "${LAST_COMMIT}..origin/${BRANCH}")
  if [ -z "${NEW_COMMITS}" ]; then
    return
  fi

  # column 6 of the import CSV is time spent per chunk, in nanoseconds
  local BENCHMARK_CSV="${NIMBUS_ETH1_BENCHMARKS_REPO}/${BENCHMARKING_TYPE}-benchmark/latest/${BENCHMARK_FILE_NAME}"
  local LAST_RUN_NANOSECONDS=$(awk -F',' 'NR>1 {sum += $6} END {print sum}' "${BENCHMARK_CSV}" 2>/dev/null)
  local LAST_RUN_SECONDS=$((LAST_RUN_NANOSECONDS / 1000000000))

  local LAST_COMMIT_TIME=$(git show -s --format=%ct "${LAST_COMMIT}")
  local THRESHOLD=$((LAST_COMMIT_TIME + LAST_RUN_SECONDS))

  local NEXT_COMMIT=$(git log --reverse --first-parent --format='%H %ct' "${LAST_COMMIT}..origin/${BRANCH}" \
    | awk -v threshold="${THRESHOLD}" '$2 >= threshold {print $1; exit}')

  # no commit landed a full run duration after the last one, but head is
  # still unbenchmarked so run it rather than waiting for a later commit
  if [ -z "${NEXT_COMMIT}" ]; then
    NEXT_COMMIT=$(echo "${NEW_COMMITS}" | head -n 1)
  fi

  echo "${NEXT_COMMIT}"
}

function cloneOrFetchNimbusRepo() {
  cloneOrFetchRepo "${NIMBUS_ETH1_REPO}" "${NIMBUS_ETH1_REPO_URL}" "${BRANCH}" "true"
  
  cd "${NIMBUS_ETH1_REPO}"
  local TARGET_COMMIT="origin/${BRANCH}"

  # Find next commit to benchmark if not forcing a run
  if [ "${FORCE_RUN}" != "true" ] && [ -d "${NIMBUS_ETH1_BENCHMARKS_REPO}" ]; then
    local LATEST_SYMLINK="${NIMBUS_ETH1_BENCHMARKS_REPO}/${BENCHMARKING_TYPE}-benchmark/latest"

    if [ -L "${LATEST_SYMLINK}" ] && [ -d "${LATEST_SYMLINK}" ]; then
      local LATEST_DIR_NAME=$(basename "$(readlink "${LATEST_SYMLINK}")")
      local LAST_COMMIT=$(echo "${LATEST_DIR_NAME}" | grep -o '_[^_]*$' | cut -c2-)

      if [ -n "${LAST_COMMIT}" ] && git cat-file -e "${LAST_COMMIT}^{commit}" 2>/dev/null; then
        echo ">>> Found last benchmarked commit: ${LAST_COMMIT}"
        local NEXT_COMMIT=$(nextCommitToBenchmark "${LAST_COMMIT}")
        if [ -n "${NEXT_COMMIT}" ]; then
          TARGET_COMMIT="${NEXT_COMMIT}"
          echo ">>> Using next commit: ${TARGET_COMMIT}"
        else
          # head is already benchmarked, skipOrContinueBenchmark stops the run
          TARGET_COMMIT="${LAST_COMMIT}"
          echo ">>> Head is already benchmarked, nothing to do"
        fi
      fi
    fi
  fi

  git reset --hard "${TARGET_COMMIT}"
  echo ">>> Current commit: $(git rev-parse --short HEAD)"
}

function cloneOrFetchBenchmarksRepo() {
  cloneOrFetchRepo "${NIMBUS_ETH1_BENCHMARKS_REPO}" "${BENCHMARKS_REPO_URL}" "master" "true"
  chown -R "$(id -u -n):$(id -g -n)" "${NIMBUS_ETH1_BENCHMARKS_REPO}"
}
