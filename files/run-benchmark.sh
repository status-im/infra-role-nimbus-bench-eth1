#!/usr/bin/env bash
# vim: ft=sh
set -e

# Source the environment configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/benchmark.env"

source /data/scripts/repo-management.sh      # Git operations
source /data/scripts/build-and-compile.sh    # Building binaries
source /data/scripts/benchmark-execution.sh  # Running benchmarks
source /data/scripts/results-processing.sh   # Processing and publishing results
source /data/scripts/metrics-collector.sh    # Metrics collection

function callAndLogFunc {
    local func_name="$1"

    echo ">>> starting ${func_name}"
    recordStageStart "${func_name}"

    local exit_code=0
    ${func_name} || exit_code=$?

    if [[ ${exit_code} -eq 0 ]]; then
        recordStageEnd "${func_name}" 1
        echo "<<< ending ${func_name} (success)"
    else
        recordStageEnd "${func_name}" 0
        echo "<<< ending ${func_name} (failed with code ${exit_code})"
        return ${exit_code}
    fi
}

# Record benchmark start timestamp
recordBenchmarkTimestamp
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
# copy files from current benchmark run to nimbus-eth1-benchmarks directory and make latest symlink
callAndLogFunc 'moveFilesFromInvocationDirectoryToBenchmarkingRepo'
# git add, commit and push the changes to nimbus-eth1-benchmarks github repo
callAndLogFunc 'publishBenchmarkingResults'
