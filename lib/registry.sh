#!/usr/bin/env bash
# lib/registry.sh — Agent registry backed by .squad/session.json
#
# The registry is the canonical roster of who has ever lived in this session:
# alive, killed, or vanished. It's the bookkeeping truth; tmux is the runtime
# truth. `squad doctor` reconciles them.
#
# All writes are guarded by an mkdir lock to survive concurrent spawns.

# Initialize session.json with a richer schema. Idempotent.
# Usage: squad_registry_init <squad_dir> <session_id> <repo_path> <model> [sprint_file] [use_worktrees]
squad_registry_init() {
  local squad_dir="$1"
  local session_id="$2"
  local repo_path="$3"
  local model="$4"
  local sprint_file="${5:-}"
  local use_worktrees="${6:-false}"
  local session_file="${squad_dir}/session.json"

  mkdir -p "$squad_dir"

  cat > "$session_file" << HEREDOC
{
  "session_id": "${session_id}",
  "repo_path": "${repo_path}",
  "sprint_file": "${sprint_file}",
  "use_worktrees": ${use_worktrees},
  "model": "${model}",
  "start_time": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "agents": []
}
HEREDOC

  echo "$session_file"
}

# Acquire the registry write lock (mkdir-based, atomic on POSIX).
# Returns 0 on success, 1 if it timed out.
_squad_registry_lock() {
  local squad_dir="$1"
  local lockfile="${squad_dir}/session.json.lock"
  local max_wait=50  # 5 seconds total
  local waited=0
  while ! mkdir "$lockfile" 2>/dev/null; do
    waited=$((waited + 1))
    if [[ $waited -ge $max_wait ]]; then
      # Force-clear a stale lock and try one more time
      rm -rf "$lockfile"
      mkdir "$lockfile" 2>/dev/null || return 1
      break
    fi
    sleep 0.1
  done
  return 0
}

_squad_registry_unlock() {
  rm -rf "${1}/session.json.lock"
}

# Append an agent record to agents[].
# Usage: squad_registry_add <squad_dir> <agent_json>
#   where agent_json is a valid JSON object like:
#   {"role":"planner","instance":1,"name":"planner","pane_id":"%0",
#    "worktree_path":"","spawned_at":"...","status":"alive"}
squad_registry_add() {
  local squad_dir="$1"
  local agent_json="$2"
  local session_file="${squad_dir}/session.json"
  local tmp="${session_file}.tmp"

  _squad_registry_lock "$squad_dir" || { echo "Error: registry lock timeout" >&2; return 1; }

  jq --argjson agent "$agent_json" '.agents += [$agent]' "$session_file" > "$tmp" && mv "$tmp" "$session_file"
  local rc=$?

  _squad_registry_unlock "$squad_dir"
  return $rc
}

# Remove ALL prior entries for <name> from agents[] (used when resurrecting
# a killed/vanished slot — the new alive entry replaces the dead one cleanly).
# Usage: squad_registry_remove <squad_dir> <name>
squad_registry_remove() {
  local squad_dir="$1"
  local name="$2"
  local session_file="${squad_dir}/session.json"
  local tmp="${session_file}.tmp"

  _squad_registry_lock "$squad_dir" || { echo "Error: registry lock timeout" >&2; return 1; }

  jq --arg name "$name" '.agents |= map(select(.name != $name))' \
    "$session_file" > "$tmp" && mv "$tmp" "$session_file"
  local rc=$?

  _squad_registry_unlock "$squad_dir"
  return $rc
}

# Mark an agent killed and record handoff path.
# Usage: squad_registry_mark_killed <squad_dir> <name> <handoff_path>
squad_registry_mark_killed() {
  local squad_dir="$1"
  local name="$2"
  local handoff_path="${3:-}"
  local session_file="${squad_dir}/session.json"
  local tmp="${session_file}.tmp"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _squad_registry_lock "$squad_dir" || { echo "Error: registry lock timeout" >&2; return 1; }

  jq --arg name "$name" --arg ts "$ts" --arg handoff "$handoff_path" '
    .agents |= map(
      if .name == $name and .status == "alive"
      then .status = "killed" | .killed_at = $ts | .handoff = $handoff
      else . end
    )
  ' "$session_file" > "$tmp" && mv "$tmp" "$session_file"
  local rc=$?

  _squad_registry_unlock "$squad_dir"
  return $rc
}

# Mark an agent as vanished (pane gone without graceful kill).
# Usage: squad_registry_mark_vanished <squad_dir> <name>
squad_registry_mark_vanished() {
  local squad_dir="$1"
  local name="$2"
  local session_file="${squad_dir}/session.json"
  local tmp="${session_file}.tmp"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _squad_registry_lock "$squad_dir" || { echo "Error: registry lock timeout" >&2; return 1; }

  jq --arg name "$name" --arg ts "$ts" '
    .agents |= map(
      if .name == $name and .status == "alive"
      then .status = "vanished" | .vanished_at = $ts
      else . end
    )
  ' "$session_file" > "$tmp" && mv "$tmp" "$session_file"
  local rc=$?

  _squad_registry_unlock "$squad_dir"
  return $rc
}

# Print the agent object for <name>, or empty.
# Usage: squad_registry_get <squad_dir> <name>
squad_registry_get() {
  local squad_dir="$1"
  local name="$2"
  local session_file="${squad_dir}/session.json"
  [[ -f "$session_file" ]] || return 0
  jq -c --arg name "$name" '.agents[] | select(.name == $name)' "$session_file" 2>/dev/null
}

# Print one TSV line per alive agent: name<TAB>pane_id<TAB>role<TAB>instance
# Usage: squad_registry_list_alive <squad_dir>
squad_registry_list_alive() {
  local squad_dir="$1"
  local session_file="${squad_dir}/session.json"
  [[ -f "$session_file" ]] || return 0
  jq -r '.agents[] | select(.status == "alive") | [.name, .pane_id, .role, (.instance|tostring)] | @tsv' "$session_file" 2>/dev/null
}

# Print a human-readable markdown roster (used by agents from inside Claude).
# Usage: squad_registry_roster_markdown <squad_dir>
squad_registry_roster_markdown() {
  local squad_dir="$1"
  local session_file="${squad_dir}/session.json"
  [[ -f "$session_file" ]] || { echo "(no session)"; return; }

  echo "# Live Roster"
  echo ""
  echo "| Name | Role | Instance | Pane | Status | Spawned |"
  echo "|------|------|----------|------|--------|---------|"
  jq -r '.agents[]
    | "| \(.name) | \(.role) | \(.instance) | \(.pane_id) | \(.status) | \(.spawned_at) |"' \
    "$session_file" 2>/dev/null
}

# Highest instance number ever assigned to <role_base>, alive or dead.
# Usage: squad_registry_max_instance <squad_dir> <role_base>
squad_registry_max_instance() {
  local squad_dir="$1"
  local role="$2"
  local session_file="${squad_dir}/session.json"
  [[ -f "$session_file" ]] || { echo "0"; return; }
  jq -r --arg role "$role" '
    [.agents[] | select(.role == $role) | .instance] | (max // 0)
  ' "$session_file" 2>/dev/null
}
