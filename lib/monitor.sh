#!/usr/bin/env bash
# lib/monitor.sh — Status dashboard and monitoring for claude-squad
# Provides terminal-based monitoring of agent states, sprint progress,
# scores, and iteration counts.

# ANSI colors
_C_RESET="\033[0m"
_C_BOLD="\033[1m"
_C_DIM="\033[2m"
_C_GREEN="\033[32m"
_C_YELLOW="\033[33m"
_C_RED="\033[31m"
_C_BLUE="\033[34m"
_C_CYAN="\033[36m"

# Show the full status dashboard
# Usage: squad_monitor_status <squad_dir> <repo_path>
squad_monitor_status() {
  local squad_dir="$1"
  local repo_path="$2"

  if [[ ! -f "${squad_dir}/session.json" ]]; then
    echo "No active squad session found."
    return 1
  fi

  local session_id start_time has_agents
  session_id=$(jq -r '.session_id' "${squad_dir}/session.json" 2>/dev/null)
  start_time=$(jq -r '.start_time' "${squad_dir}/session.json" 2>/dev/null)
  has_agents=$(jq -r 'has("agents")' "${squad_dir}/session.json" 2>/dev/null)

  echo ""
  printf "${_C_BOLD}╔══════════════════════════════════════════════════════╗${_C_RESET}\n"
  printf "${_C_BOLD}║  Claude Squad — Status Dashboard                     ║${_C_RESET}\n"
  printf "${_C_BOLD}╚══════════════════════════════════════════════════════╝${_C_RESET}\n"
  echo ""

  printf "${_C_BOLD}Session:${_C_RESET} %s\n" "$session_id"
  printf "${_C_BOLD}Started:${_C_RESET} %s\n" "$start_time"
  printf "${_C_BOLD}Repo:${_C_RESET}    %s\n" "$repo_path"
  echo ""

  printf "${_C_BOLD}── Agents ──────────────────────────────────────────${_C_RESET}\n"

  if ! tmux has-session -t "$SQUAD_SESSION" 2>/dev/null; then
    printf "  ${_C_RED}○ Session not running${_C_RESET}\n"
    echo ""
  elif [[ "$has_agents" == "true" ]]; then
    # Dynamic mode: iterate agents[] by pane_id.
    local _line _ag_name _ag_role _ag_status _ag_pane _ag_last
    while IFS=$'\t' read -r _ag_name _ag_role _ag_status _ag_pane; do
      [[ -z "$_ag_name" ]] && continue
      _ag_last=""
      if [[ "$_ag_status" == "alive" ]] && [[ -n "$_ag_pane" ]]; then
        _ag_last=$(tmux capture-pane -t "$_ag_pane" -p -S -5 2>/dev/null | \
          grep -v '^$' | tail -1 | cut -c1-60)
        printf "  ${_C_GREEN}●${_C_RESET} ${_C_BOLD}%s${_C_RESET} — ${_C_CYAN}%s${_C_RESET} ${_C_DIM}(%s)${_C_RESET}\n" \
          "$_ag_name" "$_ag_role" "$_ag_pane"
      else
        printf "  ${_C_DIM}○ %s — %s (%s)${_C_RESET}\n" "$_ag_name" "$_ag_role" "$_ag_status"
      fi
      if [[ -n "$_ag_last" ]]; then
        printf "    ${_C_DIM}%s${_C_RESET}\n" "$_ag_last"
      fi
    done < <(jq -r '.agents[] | [.name, .role, .status, .pane_id] | @tsv' "${squad_dir}/session.json" 2>/dev/null)
    echo ""
  else
    # Legacy static mode (--static or pre-dynamic session.json).
    local roles
    roles=$(jq -r '.roles[]' "${squad_dir}/session.json" 2>/dev/null)
    local pane_count
    pane_count=$(tmux list-panes -t "$SQUAD_SESSION" 2>/dev/null | wc -l | tr -d ' ')

    local i=0 _ag_icon _ag_line
    while IFS= read -r role; do
      _ag_icon="${_C_GREEN}●${_C_RESET}"
      _ag_line=""

      if (( i < pane_count )); then
        _ag_line=$(tmux capture-pane -t "${SQUAD_SESSION}:0.${i}" -p -S -5 2>/dev/null | \
          grep -v '^$' | tail -1 | cut -c1-60)
      else
        _ag_icon="${_C_RED}○${_C_RESET}"
      fi

      printf "  ${_ag_icon} ${_C_BOLD}Pane %d${_C_RESET} — ${_C_CYAN}%s${_C_RESET}\n" "$i" "$role"
      if [[ -n "$_ag_line" ]]; then
        printf "    ${_C_DIM}%s${_C_RESET}\n" "$_ag_line"
      fi

      i=$((i + 1))
    done <<< "$roles"
    echo ""
  fi

  # Sprint progress
  printf "${_C_BOLD}── Sprint Progress ─────────────────────────────────${_C_RESET}\n"

  local has_scores=false
  local _sp_num _sp_score _sp_iters _sp_color
  for score_file in "${squad_dir}"/score-sprint-*.txt; do
    if [[ -f "$score_file" ]]; then
      has_scores=true
      _sp_num=$(basename "$score_file" | grep -oE '[0-9]+')
      _sp_score=$(cat "$score_file")
      _sp_iters="?"
      if [[ -f "${squad_dir}/iteration-${_sp_num}.txt" ]]; then
        _sp_iters=$(cat "${squad_dir}/iteration-${_sp_num}.txt")
      fi

      _sp_color="$_C_RED"
      if (( $(echo "$_sp_score >= 7.0" | bc -l 2>/dev/null || echo 0) )); then
        _sp_color="$_C_GREEN"
      elif (( $(echo "$_sp_score >= 5.0" | bc -l 2>/dev/null || echo 0) )); then
        _sp_color="$_C_YELLOW"
      fi

      printf "  Sprint %s: ${_sp_color}%s/10${_C_RESET} (%s iterations)\n" \
        "$_sp_num" "$_sp_score" "$_sp_iters"
    fi
  done

  if ! $has_scores; then
    printf "  ${_C_DIM}No sprint scores yet${_C_RESET}\n"
  fi

  echo ""

  # Mailbox activity
  printf "${_C_BOLD}── Mailbox Activity ────────────────────────────────${_C_RESET}\n"

  local mailbox="${squad_dir}/mailbox.jsonl"
  if [[ -f "$mailbox" ]]; then
    local msg_count
    msg_count=$(wc -l < "$mailbox" | tr -d ' ')
    printf "  Total messages: %s\n" "$msg_count"
    echo ""
    printf "  ${_C_DIM}Last 5 messages:${_C_RESET}\n"
    local _m_from _m_to _m_type _m_body
    tail -5 "$mailbox" 2>/dev/null | while IFS= read -r line; do
      _m_from=$(echo "$line" | jq -r '.from' 2>/dev/null)
      _m_to=$(echo "$line" | jq -r '.to' 2>/dev/null)
      _m_type=$(echo "$line" | jq -r '.type' 2>/dev/null)
      _m_body=$(echo "$line" | jq -r '.body' 2>/dev/null | cut -c1-50)
      printf "    ${_C_BLUE}%s${_C_RESET} → ${_C_CYAN}%s${_C_RESET} [%s] %s\n" \
        "$_m_from" "$_m_to" "$_m_type" "$_m_body"
    done
  else
    printf "  ${_C_DIM}No mailbox activity${_C_RESET}\n"
  fi

  echo ""

  # Worktree status
  printf "${_C_BOLD}── Worktrees ───────────────────────────────────────${_C_RESET}\n"

  local wt_dir="${SQUAD_WORKTREE_DIR}/${session_id}"
  if [[ -d "$wt_dir" ]]; then
    local _wt_role _wt_st _wt_chg
    for wt in "$wt_dir"/*/; do
      if [[ -d "$wt" ]]; then
        _wt_role=$(basename "$wt")
        _wt_chg=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$_wt_chg" -eq 0 ]]; then
          _wt_st="${_C_GREEN}clean${_C_RESET}"
        else
          _wt_st="${_C_YELLOW}${_wt_chg} changes${_C_RESET}"
        fi
        printf "  %s: ${_wt_st} — %s\n" "$_wt_role" "$wt"
      fi
    done
  else
    printf "  ${_C_DIM}No worktrees (agents sharing filesystem)${_C_RESET}\n"
  fi

  echo ""
}

# Compact live view — one line per agent
# Usage: squad_monitor_compact
squad_monitor_compact() {
  if ! tmux has-session -t "$SQUAD_SESSION" 2>/dev/null; then
    echo "No active session"
    return 1
  fi

  local pane_count
  pane_count=$(tmux list-panes -t "$SQUAD_SESSION" 2>/dev/null | wc -l | tr -d ' ')

  local _cp_role _cp_line
  for ((i = 0; i < pane_count; i++)); do
    _cp_role=$(tmux show-options -t "${SQUAD_SESSION}:0.${i}" -p -v @agent_role 2>/dev/null || echo "agent-$i")
    _cp_line=$(tmux capture-pane -t "${SQUAD_SESSION}:0.${i}" -p -S -3 2>/dev/null | \
      grep -v '^$' | tail -1 | cut -c1-70)
    printf "${_C_CYAN}%-10s${_C_RESET} │ %s\n" "$_cp_role" "$_cp_line"
  done
}

# Watch mode — refresh status every N seconds
# Usage: squad_monitor_watch <squad_dir> <repo_path> [interval]
squad_monitor_watch() {
  local squad_dir="$1"
  local repo_path="$2"
  local interval="${3:-5}"

  echo "Watching squad status (Ctrl+C to stop)..."
  while true; do
    clear
    squad_monitor_status "$squad_dir" "$repo_path"
    sleep "$interval"
  done
}
