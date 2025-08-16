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

      if [ -n "${LAST_COMMIT}" ]; then
        echo ">>> Found last benchmarked commit: ${LAST_COMMIT}"
        local NEXT_COMMIT=$(git rev-list --reverse "${LAST_COMMIT}..origin/${BRANCH}" | head -n 1)
        if [ -n "${NEXT_COMMIT}" ]; then
          TARGET_COMMIT="${NEXT_COMMIT}"
          echo ">>> Using next commit: ${TARGET_COMMIT}"
        else
          echo ">>> No new commits found, using latest"
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
