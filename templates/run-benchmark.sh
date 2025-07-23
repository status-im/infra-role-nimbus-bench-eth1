#!/usr/bin/env bash
# vim: ft=sh
set -e

export NIMBUS_ETH1_BENCHMARKS_REPO="/data/status-im/nimbus-eth1-benchmarks"
export NIMBUS_ETH1_REPO="/data/status-im/nimbus-eth1"
export NIMBUS_ETH1_TEMPLATE_DB="/data/template-db"
export NIMBUS_ETH1_DB_DIR="${NIMBUS_ETH1_REPO}/data/shared_mainnet_0"
export BENCHMARK_FILE_NAME='blocks-import-benchmark.csv'
export HOST_BENCHMARKS_DIR='/data/host-benchmarks'

export ERA1_DIR='/data/era1'
export ERA_DIR='/data/era'

export NIMBUS_ETH1_REPO_URL='https://github.com/status-im/nimbus-eth1'
export BENCHMARKS_REPO_URL="git@github.com:status-im/nimbus-eth1-benchmarks.git"
export BRANCH='master'

export FORCE_RUN="${FORCE_RUN:="false"}"

export NIMBUS_ETH1_SERVICE_USER=$(id -u -n)
export NIMBUS_ETH1_SERVICE_GROUP=$(id -g -n)

export BENCHMARKING_TYPE="${BENCHMARKING_TYPE:="short"}"
export CURRENT_BENCHMARK_TYPE_DIR="${NIMBUS_ETH1_BENCHMARKS_REPO}/${BENCHMARKING_TYPE}-benchmark"

export SYSTEMD_INVOCATION_ID=$(systemctl show --value -p InvocationID nimbus-eth1-mainnet-master-"${BENCHMARKING_TYPE}"-benchmark.service)
export CURRENT_BENCHMARK_RUN_DIR="${HOST_BENCHMARKS_DIR}/${BENCHMARKING_TYPE}/${SYSTEMD_INVOCATION_ID}"
export DEBUG_CSV_PATH="${CURRENT_BENCHMARK_RUN_DIR}/${BENCHMARK_FILE_NAME}"

export README_FILE_PATH="${NIMBUS_ETH1_BENCHMARKS_REPO}/README.md"
export README_TEMPLATE_PATH="${NIMBUS_ETH1_BENCHMARKS_REPO}/README-TEMPLATE.md"

# only needed for short benchmark
export MAX_BLOCKS_TO_IMPORT=1000000

source /data/scripts/repo-management.sh      # Git operations
source /data/scripts/build-and-compile.sh    # Building binaries
source /data/scripts/benchmark-execution.sh  # Running benchmarks
source /data/scripts/results-processing.sh   # Processing and publishing results

function callAndLogFunc {
    echo ">>> starting ${1}"
    ${1}
    echo "<<< ending ${1}"
}

callAndLogFunc 'cleanBenchmarkDir'
# clones or updates the nimbus-eth1-benchmarks github repo
callAndLogFunc 'cloneOrFetchBenchmarksRepo'
# clones or updates the nimbus-eth1 github repo
callAndLogFunc 'cloneOrFetchNimbusRepo'
# builds nimbus-eth1 binary

ISO_TIMESTAMP=$(date +"%Y%m%dT%H%M%S")
GIT_HASH=$(cd "${NIMBUS_ETH1_REPO}" && git rev-parse --short=8 HEAD)
BENCHMARK_DESTINATION="${NIMBUS_ETH1_BENCHMARKS_REPO}/${BENCHMARKING_TYPE}-benchmark/${ISO_TIMESTAMP}_${GIT_HASH}"

callAndLogFunc 'buildBinaries'
# decide whether to skip or continue
callAndLogFunc 'skipOrContinueBenchmark'

if [[ "${BENCHMARKING_TYPE}" == "short" ]]; then
  # copies 20M template database to nimbus-eth1
  callAndLogFunc 'copyTemplateDatabase'
fi

# start the import process
callAndLogFunc 'startNimbusWithImport'
# move benchmark csv to nimbus-eth1-benchmarks
callAndLogFunc 'moveBenchmarkingFileToRepo'
# generate build-environment.log for current run
callAndLogFunc 'generateBuildEnvironmentLogFile'
# generates systemd service logs
callAndLogFunc 'generateSystemdServiceLogs'
# updates nimbus-eth1-benchmarks root level Readme
callAndLogFunc 'generateBenchmarkRepoReadme'
# copy files from current benchmark run to nimbus-eth1-benchmarks directory and make latest symlink
callAndLogFunc 'moveFilesFromInvocationDirectoryToBenchmarkingRepo'
# git add, commit and push the changes to nimbus-eth1-benchmarks github repo
callAndLogFunc 'publishBenchmarkingResults'
