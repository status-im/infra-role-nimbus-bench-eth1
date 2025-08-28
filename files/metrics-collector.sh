#!/usr/bin/env bash
# vim: ft=sh
set -e

METRICS_DIR="${METRICS_DIR:-/var/lib/nimbus-benchmark-metrics}"
METRICS_FILE="${METRICS_DIR}/benchmark_metrics.yaml"
STAGE_TIMINGS_FILE="${METRICS_DIR}/.stage_timings"

function initMetricsDir() {
    mkdir -p "${METRICS_DIR}"
}

function ensureMetricsFile() {
    initMetricsDir
    if [[ ! -f "${METRICS_FILE}" ]]; then
        cat > "${METRICS_FILE}" << 'EOF'
benchmark_type: ""
last_run_timestamp: 0
metadata:
  git_hash: ""
  start_block: ""
  end_block: ""
  total_blocks: 0
stages: {}
EOF
    fi
}

function updateYamlField() {
    local key="$1"
    local value="$2"
    local file="${METRICS_FILE}"

    if grep -q "^${key}:" "${file}" 2>/dev/null; then
        sed -i.bak "s|^${key}:.*|${key}: ${value}|" "${file}" && rm -f "${file}.bak"
    else
        echo "${key}: ${value}" >> "${file}"
    fi
}

function recordStageStart() {
    local stage_name="$1"
    local start_time=$(date +%s%N)

    initMetricsDir
    echo "${stage_name}_start=${start_time}" >> "${STAGE_TIMINGS_FILE}"
}

function recordStageEnd() {
    local stage_name="$1"
    local success="$2"  # 0 for failure, 1 for success
    local end_time=$(date +%s%N)

    ensureMetricsFile

    local start_time=$(grep "^${stage_name}_start=" "${STAGE_TIMINGS_FILE}" 2>/dev/null | cut -d= -f2 | tail -1)

    if [[ -n "${start_time}" ]]; then
        local duration_ns=$((end_time - start_time))
        local duration_seconds=$(echo "scale=6; ${duration_ns} / 1000000000" | bc | sed 's/^\./0./')

        # Update stages section in YAML
        # Remove old stage entry if exists, then add new one
        local temp_file="${METRICS_DIR}/.metrics_tmp.yaml"

        # Check if stages section exists and has content
        if grep -q "^stages:" "${METRICS_FILE}"; then
            # Remove existing stage entry for this stage_name
            awk -v stage="${stage_name}" '
                BEGIN { in_stages = 0; skip_stage = 0 }
                /^stages:/ { in_stages = 1; print; next }
                in_stages && /^  [a-zA-Z_]+:/ {
                    if ($1 == stage":") { skip_stage = 1; next }
                    else { skip_stage = 0 }
                }
                in_stages && /^[a-zA-Z]/ { in_stages = 0; skip_stage = 0 }
                !skip_stage { print }
            ' "${METRICS_FILE}" > "${temp_file}"

            # Check if stages: {} (empty)
            if grep -q "^stages: {}$" "${temp_file}"; then
                sed -i.bak "s|^stages: {}$|stages:|" "${temp_file}" && rm -f "${temp_file}.bak"
            fi

            # Add the new stage entry
            awk -v stage="${stage_name}" -v success="${success}" -v duration="${duration_seconds}" '
                /^stages:$/ {
                    print
                    print "  " stage ":"
                    print "    success: " success
                    print "    duration_seconds: " duration
                    next
                }
                { print }
            ' "${temp_file}" > "${METRICS_FILE}"
            rm -f "${temp_file}"
        fi
    fi
}

function recordBenchmarkMetadata() {
    local git_hash="$1"
    local start_block="$2"
    local end_block="$3"
    local total_blocks="$4"

    ensureMetricsFile

    local temp_file="${METRICS_DIR}/.metrics_tmp.yaml"

    # Update metadata section
    awk -v git_hash="${git_hash}" -v start_block="${start_block}" \
        -v end_block="${end_block}" -v total_blocks="${total_blocks}" '
        BEGIN { in_metadata = 0 }
        /^metadata:/ {
            print "metadata:"
            print "  git_hash: \"" git_hash "\""
            print "  start_block: \"" start_block "\""
            print "  end_block: \"" end_block "\""
            print "  total_blocks: " total_blocks
            in_metadata = 1
            next
        }
        in_metadata && /^[a-zA-Z]/ { in_metadata = 0 }
        !in_metadata { print }
    ' "${METRICS_FILE}" > "${temp_file}"

    mv "${temp_file}" "${METRICS_FILE}"

    # Also update benchmark_type at top level
    updateYamlField "benchmark_type" "\"${BENCHMARKING_TYPE}\""
}

function recordBenchmarkTimestamp() {
    local timestamp=$(date +%s)

    ensureMetricsFile
    updateYamlField "last_run_timestamp" "${timestamp}"
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
