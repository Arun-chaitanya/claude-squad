#!/usr/bin/env bash
# lib/tmux.sh — tmux session management for claude-squad
# Creates sessions, manages panes, captures output, sends signals.
#
# The tmux session name is derived from $SQUAD_NAME so multiple squads can
# run in parallel (one tmux session per squad). $SQUAD_NAME defaults to
# "default" — preserving the single-squad workflow when no name is given.
# bin/squad calls squad_tmux_set_session_name after parsing --name flags
# (and after reading the .squad/current pointer) so the right session is
# targeted for every command.

: "${SQUAD_NAME:=default}"
SQUAD_SESSION="claude-squad-${SQUAD_NAME}"

# Re-derive SQUAD_SESSION from $SQUAD_NAME. Call after changing SQUAD_NAME.
squad_tmux_set_session_name() {
  SQUAD_SESSION="claude-squad-${SQUAD_NAME}"
}

# Configure mouse behavior on a session:
#   - mouse on  → clicking a pane focuses it
#   - wheel rebinds → ALWAYS scroll tmux's own scrollback buffer (copy-mode),
#     even inside alternate-screen apps like Claude Code. Claude Code maps
#     wheel-up to <Up arrow> (history navigation, not chat scroll), so the
#     useful behavior is to bypass the app entirely and let tmux do the
#     scrolling. Page-by-page scroll for fewer clicks.
# Usage: squad_tmux_configure_mouse <session>
squad_tmux_configure_mouse() {
  local session="$1"
  tmux set-option -t "$session" mouse on >/dev/null
  # Tall history buffer so chat scroll-back is meaningful.
  tmux set-option -t "$session" history-limit 50000 >/dev/null

  tmux bind-key -T root WheelUpPane \
    "select-pane -t = ; if -F -t = '#{?pane_in_mode,1,0}' \
       'send-keys -M' \
       'copy-mode -e ; send-keys -X -N 3 scroll-up'" >/dev/null

  tmux bind-key -T root WheelDownPane \
    "select-pane -t = ; if -F -t = '#{?pane_in_mode,1,0}' \
       'send-keys -X -N 3 scroll-down' \
       'send-keys -M'" >/dev/null
}

# ─── Dynamic pane helpers (Stories 2+3) ────────────────────────────────────
# These primitives work with stable tmux pane ids (%N), set on each pane via
# user options @agent_role / @agent_instance / @agent_spawned_at.
# Pane ids survive layout changes, manual swaps, and other panes being killed.

# Look up the pane id (%N) for a role-instance name (e.g. "coder", "coder-2").
# Convention: "coder" matches instance 1 of role "coder" when it's the only
# alive instance; otherwise the caller must pass the suffixed name.
# Usage: squad_tmux_pane_for_name <name>
squad_tmux_pane_for_name() {
  local name="$1"
  local role instance
  if [[ "$name" =~ ^(.+)-([0-9]+)$ ]]; then
    role="${BASH_REMATCH[1]}"
    instance="${BASH_REMATCH[2]}"
  else
    role="$name"
    instance="1"
  fi
  tmux list-panes -t "$SQUAD_SESSION" \
    -F '#{pane_id} #{@agent_role} #{@agent_instance}' 2>/dev/null \
    | awk -v r="$role" -v n="$instance" '$2==r && $3==n {print $1; exit}'
}

# List one TSV line per alive pane: pane_id<TAB>role<TAB>instance.
# Usage: squad_tmux_list_agents
squad_tmux_list_agents() {
  tmux list-panes -t "$SQUAD_SESSION" \
    -F '#{pane_id}	#{@agent_role}	#{@agent_instance}' 2>/dev/null \
    | awk -F'\t' '$2 != "" {print}'
}

# Spawn a new pane for a role, label it, and launch a command.
# Returns the new pane id on stdout.
# Usage: squad_tmux_spawn <role> <instance> <command>
squad_tmux_spawn() {
  local role="$1"
  local instance="$2"
  local command="$3"

  if ! tmux has-session -t "$SQUAD_SESSION" 2>/dev/null; then
    echo "Error: no active session '$SQUAD_SESSION'" >&2
    return 1
  fi

  # Split from the planner's pane when available, otherwise from the first pane.
  local target
  target=$(squad_tmux_pane_for_name "planner")
  if [[ -z "$target" ]]; then
    target=$(tmux list-panes -t "$SQUAD_SESSION" -F '#{pane_id}' | head -1)
  fi

  # -P prints the new pane id; -F controls its format.
  local new_id
  new_id=$(tmux split-window -t "$target" -P -F '#{pane_id}')
  tmux select-layout -t "$SQUAD_SESSION" tiled >/dev/null

  tmux set-option -t "$new_id" -p @agent_role "$role"
  tmux set-option -t "$new_id" -p @agent_instance "$instance"
  tmux set-option -t "$new_id" -p @agent_spawned_at "$(date -u +%s)"

  tmux send-keys -t "$new_id" "$command" Enter
  echo "$new_id"
}

# Kill a pane by id and re-tile.
# Usage: squad_tmux_kill_pane <pane_id>
squad_tmux_kill_pane() {
  local pane_id="$1"
  tmux kill-pane -t "$pane_id" 2>/dev/null || true
  # Re-tile if the session still exists
  if tmux has-session -t "$SQUAD_SESSION" 2>/dev/null; then
    tmux select-layout -t "$SQUAD_SESSION" tiled >/dev/null 2>&1 || true
  fi
}

# How many panes are alive in the session.
# Usage: squad_tmux_pane_count_live
squad_tmux_pane_count_live() {
  tmux list-panes -t "$SQUAD_SESSION" 2>/dev/null | wc -l | tr -d ' '
}

# ──────────────────────────────────────────────────────────────────────────

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
  squad_tmux_configure_mouse "$SQUAD_SESSION"
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
  squad_tmux_configure_mouse "$SQUAD_SESSION"

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

# Nudge a pane by its tmux pane_id (e.g. "%7"), independent of positional index.
# Used by `squad mail` to notify any addressable agent.
# Usage: squad_tmux_nudge_pane <pane_id> <from> <type>
squad_tmux_nudge_pane() {
  local pane_id="$1"
  local from="$2"
  local msg_type="$3"
  tmux send-keys -t "$pane_id" \
    "# 📬 mail from ${from} (${msg_type}) — run: squad inbox" Enter
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
