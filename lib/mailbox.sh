#!/usr/bin/env bash
# lib/mailbox.sh — JSONL mailbox for inter-agent communication
# Agents write JSON messages to .squad/mailbox.jsonl
# Messages are append-only; agents read by filtering on their role.

# Initialize the mailbox file
squad_mailbox_init() {
  local squad_dir="$1"
  local mailbox="${squad_dir}/mailbox.jsonl"
  : > "$mailbox"
  echo "$mailbox"
}

# Send a message to the mailbox
# Usage: squad_mailbox_send <squad_dir> <from_role> <to_role> <type> <body>
# Types: notification, request, result, bug, status_update, sprint_contract
squad_mailbox_send() {
  local squad_dir="$1"
  local from="$2"
  local to="$3"
  local msg_type="$4"
  local body="$5"
  local mailbox="${squad_dir}/mailbox.jsonl"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local lockfile="${mailbox}.lock"
  local body_json
  body_json=$(printf '%s' "$body" | jq -Rs .)
  local line
  line=$(printf '{"ts":"%s","from":"%s","to":"%s","type":"%s","body":%s}' \
    "$timestamp" "$from" "$to" "$msg_type" "$body_json")

  # Use mkdir-based lock (atomic on all POSIX systems, works on macOS)
  local max_wait=10
  local waited=0
  while ! mkdir "$lockfile" 2>/dev/null; do
    waited=$((waited + 1))
    if [[ $waited -ge $max_wait ]]; then
      # Stale lock — force remove and retry
      rm -rf "$lockfile"
      mkdir "$lockfile" 2>/dev/null || true
      break
    fi
    sleep 0.1
  done

  echo "$line" >> "$mailbox"
  rm -rf "$lockfile"
}

# Read all messages for a specific recipient
# Usage: squad_mailbox_read <squad_dir> <role>
squad_mailbox_read() {
  local squad_dir="$1"
  local role="$2"
  local mailbox="${squad_dir}/mailbox.jsonl"

  if [[ ! -f "$mailbox" ]]; then
    return 0
  fi

  jq -c "select(.to == \"$role\" or .to == \"all\")" "$mailbox" 2>/dev/null
}

# Read messages since a given timestamp
# Usage: squad_mailbox_read_since <squad_dir> <role> <since_timestamp>
squad_mailbox_read_since() {
  local squad_dir="$1"
  local role="$2"
  local since="$3"
  local mailbox="${squad_dir}/mailbox.jsonl"

  if [[ ! -f "$mailbox" ]]; then
    return 0
  fi

  jq -c "select((.to == \"$role\" or .to == \"all\") and .ts > \"$since\")" "$mailbox" 2>/dev/null
}

# Get the last N messages
# Usage: squad_mailbox_tail <squad_dir> [n]
squad_mailbox_tail() {
  local squad_dir="$1"
  local n="${2:-10}"
  local mailbox="${squad_dir}/mailbox.jsonl"

  if [[ ! -f "$mailbox" ]]; then
    return 0
  fi

  tail -n "$n" "$mailbox"
}

# Count unread messages for a role (messages after last read timestamp)
# Usage: squad_mailbox_count <squad_dir> <role>
squad_mailbox_count() {
  local squad_dir="$1"
  local role="$2"
  local mailbox="${squad_dir}/mailbox.jsonl"

  if [[ ! -f "$mailbox" ]]; then
    echo "0"
    return
  fi

  jq -c "select(.to == \"$role\" or .to == \"all\")" "$mailbox" 2>/dev/null | wc -l | tr -d ' '
}

# Get full mailbox path
squad_mailbox_path() {
  local squad_dir="$1"
  echo "${squad_dir}/mailbox.jsonl"
}
