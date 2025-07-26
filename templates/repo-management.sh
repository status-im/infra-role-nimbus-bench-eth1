#!/usr/bin/env bash
# vim: ft=sh
set -e

function cloneOrFetchNimbusRepo() {
  mkdir -p "${NIMBUS_ETH1_REPO}"
  chmod 775 "${NIMBUS_ETH1_REPO}"

  if [ -d "${NIMBUS_ETH1_REPO}/.git" ]; then
    cd "${NIMBUS_ETH1_REPO}"
    git clean -fdx >/dev/null 2>&1
    git submodule foreach --recursive git clean -fdx >/dev/null 2>&1
    echo ">>> Fetching latest changes..."
    git fetch
  else
    echo ">>> Cloning repo..."
    git clone -b "${BRANCH}" "${NIMBUS_ETH1_REPO_URL}" "${NIMBUS_ETH1_REPO}"
    cd "${NIMBUS_ETH1_REPO}"
  fi

  local TARGET_COMMIT="origin/${BRANCH}"

  if [ "${FORCE_RUN}" != "true" ] && [ -d "${NIMBUS_ETH1_BENCHMARKS_REPO}" ]; then
    local LATEST_SYMLINK="${NIMBUS_ETH1_BENCHMARKS_REPO}/${BENCHMARKING_TYPE}-benchmark/latest"

    if [ -L "${LATEST_SYMLINK}" ] && [ -d "${LATEST_SYMLINK}" ]; then
      local LATEST_DIR_NAME=$(basename "$(readlink "${LATEST_SYMLINK}")")
      local LAST_COMMIT=$(echo "${LATEST_DIR_NAME}" | grep -o '_[^_]*$' | cut -c2-)

      if [ -n "${LAST_COMMIT}" ]; then
        echo ">>> Found last benchmarked commit: ${LAST_COMMIT}"
        git checkout "${BRANCH}"
        git reset --hard "origin/${BRANCH}"

        # Get the next commit
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
  # Check if git repo already exists
  if [ -d "${NIMBUS_ETH1_BENCHMARKS_REPO}/.git" ]; then
    echo ">>> Fetching latest benchmarks from github"

    cd "${NIMBUS_ETH1_BENCHMARKS_REPO}"
    git fetch
    git reset --hard "origin/master"
  else
    echo ">>> Cloning benchmarks"
    mkdir -p "${NIMBUS_ETH1_BENCHMARKS_REPO}"
    git clone -b "master" "${BENCHMARKS_REPO_URL}" "${NIMBUS_ETH1_BENCHMARKS_REPO}"
  fi

  chown -R "$(id -u -n):$(id -g -n)" "${NIMBUS_ETH1_BENCHMARKS_REPO}"
}

function cleanBenchmarkDir() {
  if [ ! -d "${NIMBUS_ETH1_BENCHMARKS_REPO}" ]; then
    echo ">>> Benchmark directory ${NIMBUS_ETH1_BENCHMARKS_REPO} does not exist, skipping cleanup"
    return 0
  fi

  git -C "${NIMBUS_ETH1_BENCHMARKS_REPO}" clean -dfx
}
