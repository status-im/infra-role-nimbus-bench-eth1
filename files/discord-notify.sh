#!/usr/bin/env bash
# vim: ft=sh
# Delivers an alert to the Discord webhook when a benchmark run fails.

function sendDiscordAlert() {
    local benchmark_type="$1"
    local message="$2"

    [[ -n "${DISCORD_WEBHOOK_URL:-}" ]] || return 0

    message="[critical] ${benchmark_type} benchmark on $(hostname -s): ${message}"
    [[ -n "${DISCORD_MENTION_ID:-}" ]] && message="<@${DISCORD_MENTION_ID}> ${message}"

    # discord caps message content at 2000 characters, truncate before escaping so
    # the cut cannot land in the middle of an escape sequence
    message="${message:0:1900}"
    message="${message//\\/\\\\}"
    message="${message//\"/\\\"}"
    message="${message//$'\n'/\\n}"

    printf '{"content":"%s","allowed_mentions":{"parse":["users"]}}' "${message}" \
      | curl -sS -X POST -H 'Content-Type: application/json' --max-time 15 \
             --data @- "${DISCORD_WEBHOOK_URL}" >/dev/null \
      || echo "WARNING: failed to deliver discord notification"

    return 0
}
