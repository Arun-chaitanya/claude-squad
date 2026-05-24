#!/usr/bin/env bash
# lib/tmux.sh — tmux session management for claude-squad
# Creates sessions, manages panes, captures output, sends signals.

SQUAD_SESSION="claude-squad"

# Create the tmux session with a single pane for one role.
# Used by the default dynamic boot path — additional panes are spawned later.
# Usage: squad_tmux_create_single_pane <role> [instance]
squad_tmux_create_single_pane() {
  local role="$1"
  local instance="${2:-1}"

  if tmux has-session -t "$SQUAD_SESSION" 2>/dev/null; then
    echo "Error: session '$SQUAD_SESSION' already exists. Run 'squad stop' first." >&2
    return 1
  fi

  tmux new-session -d -s "$SQUAD_SESSION" -x 200 -y 50
  local pane_id
  pane_id=$(tmux list-panes -t "$SQUAD_SESSION" -F '#{pane_id}' | head -1)

  tmux set-option -t "$pane_id" -p @agent_role "$role"
  tmux set-option -t "$pane_id" -p @agent_instance "$instance"
  tmux set-option -t "$pane_id" -p @agent_spawned_at "$(date -u +%s)"

  echo "$pane_id"
}

# Create the tmux session with N panes (one per role). Legacy fixed-roster boot.
# Usage: squad_tmux_create_session <role1> <role2> ...
squad_tmux_create_session() {
  local roles=("$@")
  local num_roles=${#roles[@]}

  if tmux has-session -t "$SQUAD_SESSION" 2>/dev/null; then
    echo "Error: session '$SQUAD_SESSION' already exists. Run 'squad stop' first." >&2
    return 1
  fi

  # Create session with first pane
  tmux new-session -d -s "$SQUAD_SESSION" -x 200 -y 50

  # Create additional panes
  for ((i = 1; i < num_roles; i++)); do
    tmux split-window -t "$SQUAD_SESSION" -h
    tmux select-layout -t "$SQUAD_SESSION" tiled
  done

  # Name each pane via tmux user variable
  for ((i = 0; i < num_roles; i++)); do
    tmux set-option -t "${SQUAD_SESSION}:0.${i}" -p @agent_role "${roles[$i]}"
    tmux set-option -t "${SQUAD_SESSION}:0.${i}" -p @agent_index "$i"
  done

  echo "Created tmux session '$SQUAD_SESSION' with ${num_roles} panes"
}

# Kill the squad tmux session
squad_tmux_kill_session() {
  if tmux has-session -t "$SQUAD_SESSION" 2>/dev/null; then
    tmux kill-session -t "$SQUAD_SESSION"
    echo "Killed session '$SQUAD_SESSION'"
  else
    echo "No active session '$SQUAD_SESSION'"
  fi
}

# Send keys to a pane identified by tmux pane_id (e.g. %0, %3).
# Usage: squad_tmux_send_pane <pane_id> <keys>
squad_tmux_send_pane() {
  local pane_id="$1"
  shift
  tmux send-keys -t "$pane_id" "$*" Enter
}

# Launch a command in a pane identified by tmux pane_id.
# Usage: squad_tmux_launch_pane <pane_id> <command>
squad_tmux_launch_pane() {
  local pane_id="$1"
  shift
  tmux send-keys -t "$pane_id" "$*" Enter
}

# Send keys to a specific pane (legacy, positional index).
# Usage: squad_tmux_send <pane_index> <keys>
squad_tmux_send() {
  local pane_index="$1"
  shift
  tmux send-keys -t "${SQUAD_SESSION}:0.${pane_index}" "$*" Enter
}

# Send a short notification nudge to a pane (not the full message — just a signal)
# The actual message content is in the mailbox file
# Usage: squad_tmux_nudge <pane_index> <signal_word>
squad_tmux_nudge() {
  local pane_index="$1"
  local signal="$2"
  # We type a comment that the agent's Claude Code session will see
  tmux send-keys -t "${SQUAD_SESSION}:0.${pane_index}" \
    "# SIGNAL: ${signal} — check .squad/mailbox.jsonl for details" Enter
}

# Capture the current visible output of a pane
# Usage: squad_tmux_capture <pane_index> [lines]
squad_tmux_capture() {
  local pane_index="$1"
  local lines="${2:-50}"
  tmux capture-pane -t "${SQUAD_SESSION}:0.${pane_index}" -p -S "-${lines}"
}

# Launch a command in a specific pane
# Usage: squad_tmux_launch <pane_index> <command>
squad_tmux_launch() {
  local pane_index="$1"
  shift
  tmux send-keys -t "${SQUAD_SESSION}:0.${pane_index}" "$*" Enter
}

# Check if session exists
squad_tmux_session_exists() {
  tmux has-session -t "$SQUAD_SESSION" 2>/dev/null
}

# Get the number of panes in the session
squad_tmux_pane_count() {
  tmux list-panes -t "$SQUAD_SESSION" 2>/dev/null | wc -l | tr -d ' '
}

# List all panes with their roles
squad_tmux_list_panes() {
  if ! squad_tmux_session_exists; then
    echo "No active session"
    return 1
  fi
  local count
  count=$(squad_tmux_pane_count)
  local _lp_role
  for ((i = 0; i < count; i++)); do
    _lp_role=$(tmux show-options -t "${SQUAD_SESSION}:0.${i}" -p -v @agent_role 2>/dev/null || echo "unknown")
    echo "Pane $i: $_lp_role"
  done
}

# Send Escape keys to unstick a pane (escalation protocol)
squad_tmux_unstick() {
  local pane_index="$1"
  tmux send-keys -t "${SQUAD_SESSION}:0.${pane_index}" Escape
  tmux send-keys -t "${SQUAD_SESSION}:0.${pane_index}" Escape
}

# Send /clear to reset an agent's context (hard reset)
squad_tmux_clear_context() {
  local pane_index="$1"
  tmux send-keys -t "${SQUAD_SESSION}:0.${pane_index}" "/clear" Enter
}

# Attach to the squad session (for interactive monitoring)
squad_tmux_attach() {
  if squad_tmux_session_exists; then
    tmux attach-session -t "$SQUAD_SESSION"
  else
    echo "No active session '$SQUAD_SESSION'" >&2
    return 1
  fi
}
