#!/usr/bin/env bash
# vim: ft=sh
set -e

METRICS_DIR="${METRICS_DIR:-/var/lib/nimbus-benchmark-metrics}"
METRICS_FILE="${METRICS_DIR}/benchmark_metrics.prom"
METRICS_TMP="${METRICS_DIR}/.benchmark_metrics.tmp"

function initMetricsDir() {
    mkdir -p "${METRICS_DIR}"
    if [[ ! -f "${METRICS_FILE}" ]]; then
        touch "${METRICS_FILE}"
    fi
}

function recordStageStart() {
    local stage_name="$1"
    local timestamp=$(date +%s%N)

    initMetricsDir

    echo "${stage_name}_start=${timestamp}" >> "${METRICS_DIR}/.stage_timings"
}

function recordStageEnd() {
    local stage_name="$1"
    local success="$2"  # 0 for failure, 1 for success
    local end_time=$(date +%s%N)

    initMetricsDir

    local start_time=$(grep "^${stage_name}_start=" "${METRICS_DIR}/.stage_timings" 2>/dev/null | cut -d= -f2 | tail -1)

    if [[ -n "${start_time}" ]]; then
        local duration_ns=$((end_time - start_time))
        local duration_seconds=$(echo "scale=6; ${duration_ns} / 1000000000" | bc)

        {
            # Filter out old metrics
            if [[ -f "${METRICS_FILE}" ]]; then
                grep -v "^nimbus_benchmark_stage_success{.*stage_name=\"${stage_name}\"" "${METRICS_FILE}" 2>/dev/null | \
                grep -v "^nimbus_benchmark_stage_duration_seconds{.*stage_name=\"${stage_name}\"" || true
            fi
            echo "nimbus_benchmark_stage_success{stage_name=\"${stage_name}\",benchmark_type=\"${BENCHMARKING_TYPE}\"} ${success}"
            echo "nimbus_benchmark_stage_duration_seconds{stage_name=\"${stage_name}\",benchmark_type=\"${BENCHMARKING_TYPE}\"} ${duration_seconds}"
        } > "${METRICS_TMP}"

        mv "${METRICS_TMP}" "${METRICS_FILE}"
    fi
}

function recordBenchmarkMetadata() {
    local git_hash="$1"
    local start_block="$2"
    local end_block="$3"
    local total_blocks="$4"

    initMetricsDir

    {
        if [[ -f "${METRICS_FILE}" ]]; then
            grep -v "^nimbus_benchmark_info{" "${METRICS_FILE}" 2>/dev/null | \
            grep -v "^nimbus_benchmark_total_blocks{" || true
        fi
        echo "nimbus_benchmark_info{git_hash=\"${git_hash}\",benchmark_type=\"${BENCHMARKING_TYPE}\",start_block=\"${start_block}\",end_block=\"${end_block}\"} 1"
        echo "nimbus_benchmark_total_blocks{benchmark_type=\"${BENCHMARKING_TYPE}\"} ${total_blocks}"
    } > "${METRICS_TMP}"

    mv "${METRICS_TMP}" "${METRICS_FILE}"
}

function recordBenchmarkTimestamp() {
    local timestamp=$(date +%s)

    initMetricsDir

    {
        if [[ -f "${METRICS_FILE}" ]]; then
            grep -v "^nimbus_benchmark_last_run_timestamp{.*benchmark_type=\"${BENCHMARKING_TYPE}\"" "${METRICS_FILE}" 2>/dev/null || true
        fi
        echo "nimbus_benchmark_last_run_timestamp{benchmark_type=\"${BENCHMARKING_TYPE}\"} ${timestamp}"
    } > "${METRICS_TMP}"

    mv "${METRICS_TMP}" "${METRICS_FILE}"
}

export -f recordStageStart
export -f recordStageEnd
export -f recordBenchmarkMetadata
export -f recordBenchmarkTimestamp

# Only run main logic if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

    case "${1:-}" in
        start)
            recordStageStart "$2"
            ;;
        end)
            recordStageEnd "$2" "$3"
            ;;
        metadata)
            recordBenchmarkMetadata "$2" "$3" "$4" "$5"
            ;;
        timestamp)
            recordBenchmarkTimestamp
            ;;
        *)
            echo "Usage: $0 {start|end|metadata|timestamp} [arguments]"
            echo "  start <stage_name>                                      - Record stage start"
            echo "  end <stage_name> <success>                              - Record stage end (success: 0 or 1)"
            echo "  metadata <git_hash> <start_block> <end_block> <total>   - Record benchmark metadata"
            echo "  timestamp                                               - Record current timestamp"
            echo ""
            exit 1
            ;;
    esac
fi
