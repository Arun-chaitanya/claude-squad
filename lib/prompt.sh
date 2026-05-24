#!/usr/bin/env bash
# lib/prompt.sh — Generate per-role system prompt files
# Each agent gets a prompt file injected via --append-system-prompt-file
# containing: role definition + pane index + repo context + sprint file + harness protocol

SQUAD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Dynamic-mode prompt generator. The agent is identified by its role-instance
# name (e.g. "planner", "coder-2"); pane index and total panes are NOT baked
# in because the topology changes at runtime.
# Usage: squad_prompt_generate_dynamic <squad_dir> <name> <role_base> <repo_path> [sprint_file]
squad_prompt_generate_dynamic() {
  local squad_dir="$1"
  local name="$2"
  local role_base="$3"
  local repo_path="$4"
  local sprint_file="${5:-}"
  local role_file="${SQUAD_SCRIPT_DIR}/roles/${role_base}.md"
  local prompt_file="${squad_dir}/prompt-${name}.md"

  if [[ ! -f "$role_file" ]]; then
    echo "Error: role file not found: $role_file" >&2
    return 1
  fi

  cat > "$prompt_file" << HEREDOC
# Claude Squad — Agent Prompt
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Session Context
- **Your name**: ${name}
- **Your role**: ${role_base}
- **Repository**: ${repo_path}
- **Squad directory**: ${squad_dir}
- **Mailbox**: ${squad_dir}/mailbox.jsonl

## Live Roster
The set of active agents changes over time. Look up the current roster on demand;
do NOT cache it. Useful commands from inside the pane:

\`\`\`bash
squad roster                                      # markdown table of alive agents
jq '.agents' ${squad_dir}/session.json            # full registry (history + status)
\`\`\`

Re-check before sending mailbox messages so you address the right peer.
HEREDOC

  # NOTE: We intentionally do NOT auto-inject a resume preamble even when a
  # prior handoff file exists. The harness provides the mechanism (handoff
  # files persist across kill/spawn); whoever invokes the spawn (usually the
  # planner) decides whether and how to brief the new instance about it.
  # See PLAN.md "Design intent" and memory feedback-harness-provides-mechanisms-not-policies.

  # Sprint file reference if provided
  if [[ -n "$sprint_file" ]] && [[ -f "$sprint_file" ]]; then
    cat >> "$prompt_file" << HEREDOC

## Sprint File
The sprint file is at: ${sprint_file}
Read it to understand the current project state and your assignments.
HEREDOC
  fi

  cat >> "$prompt_file" << HEREDOC

## Role Definition
$(cat "$role_file")

## Mailbox Quick-Reference

### Read messages addressed to you
\`\`\`bash
jq -c 'select(.to == "${name}" or .to == "all")' ${squad_dir}/mailbox.jsonl
\`\`\`

### Send a message
\`\`\`bash
echo '{"ts":"'\$(date -u +%Y-%m-%dT%H:%M:%SZ)'","from":"${name}","to":"TARGET_NAME","type":"MESSAGE_TYPE","body":"Your message"}' >> ${squad_dir}/mailbox.jsonl
\`\`\`

## Begin
Start by reading the mailbox and any handoff file, then begin your workflow.
HEREDOC

  echo "$prompt_file"
}

# Dynamic-mode launcher generator. Pairs with squad_prompt_generate_dynamic.
# Usage: squad_prompt_launcher_dynamic <squad_dir> <name> <work_dir> [model] [session_id] [resume]
#   session_id: claude UUID for this agent (fresh spawn assigns one; resume reuses it)
#   resume:     "1" to use --resume, anything else / unset for --session-id (fresh)
squad_prompt_launcher_dynamic() {
  local squad_dir="$1"
  local name="$2"
  local work_dir="$3"
  local model="${4:-claude-opus-4-6}"
  local session_id="${5:-}"
  local resume="${6:-0}"
  local prompt_file="${squad_dir}/prompt-${name}.md"
  local launch_file="${squad_dir}/launch-${name}.sh"

  local session_flag=""
  if [[ -n "$session_id" ]]; then
    if [[ "$resume" == "1" ]]; then
      session_flag="--resume \"${session_id}\""
    else
      session_flag="--session-id \"${session_id}\""
    fi
  fi

  cat > "$launch_file" << HEREDOC
#!/usr/bin/env bash
# Auto-generated launcher for ${name} agent
cd "${work_dir}"
exec claude --dangerously-skip-permissions --append-system-prompt-file "${prompt_file}" --model "${model}" ${session_flag}
HEREDOC

  chmod +x "$launch_file"
  echo "$launch_file"
}

# Generate a prompt file for a specific role
# Usage: squad_prompt_generate <squad_dir> <role_name> <pane_index> <repo_path> <total_panes> [sprint_file]
squad_prompt_generate() {
  local squad_dir="$1"
  local role_name="$2"
  local pane_index="$3"
  local repo_path="$4"
  local total_panes="$5"
  local sprint_file="${6:-}"
  local role_file="${SQUAD_SCRIPT_DIR}/roles/${role_name}.md"
  local prompt_file="${squad_dir}/prompt-${role_name}.md"

  if [[ ! -f "$role_file" ]]; then
    echo "Error: role file not found: $role_file" >&2
    return 1
  fi

  # Build the prompt
  cat > "$prompt_file" << HEREDOC
# Claude Squad — Agent Prompt
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Session Context
- **Your role**: ${role_name}
- **Your pane index**: ${pane_index}
- **Total panes**: ${total_panes}
- **Repository**: ${repo_path}
- **Squad directory**: ${squad_dir}
- **Mailbox**: ${squad_dir}/mailbox.jsonl

## Pane Map
HEREDOC

  # Add pane map from session.json if it exists
  if [[ -f "${squad_dir}/session.json" ]]; then
    local roles_json
    roles_json=$(jq -r '.roles[]' "${squad_dir}/session.json" 2>/dev/null)
    local idx=0
    while IFS= read -r r; do
      echo "- Pane $idx: **${r}**" >> "$prompt_file"
      idx=$((idx + 1))
    done <<< "$roles_json"
  fi

  echo "" >> "$prompt_file"

  # Add sprint file reference if provided
  if [[ -n "$sprint_file" ]] && [[ -f "$sprint_file" ]]; then
    cat >> "$prompt_file" << HEREDOC
## Sprint File
The sprint file is at: ${sprint_file}
Read it to understand the current project state and your assignments.

HEREDOC
  fi

  # Add the role definition
  cat >> "$prompt_file" << HEREDOC
## Role Definition
$(cat "$role_file")

## Harness Communication Protocol

### Reading the Mailbox
To check for new messages addressed to you:
\`\`\`bash
cat ${squad_dir}/mailbox.jsonl | grep '"to":"${role_name}"'
\`\`\`

### Sending a Message
\`\`\`bash
echo '{"ts":"'\$(date -u +%Y-%m-%dT%H:%M:%SZ)'","from":"${role_name}","to":"TARGET_ROLE","type":"MESSAGE_TYPE","body":"Your message"}' >> ${squad_dir}/mailbox.jsonl
\`\`\`

### Context Reset Protocol
Between sprints, reset your context to avoid quality degradation from long conversations.
After you complete a sprint's work unit and send all notifications:
1. Write a brief checkpoint to the sprint file (what you did, current state)
2. Run: \`/clear\`
3. After the clear, immediately re-read the sprint file and mailbox to restore context
4. Continue with your next work unit

This keeps your context fresh — the sprint file and mailbox are your persistent memory.

## Begin
Start by reading the sprint file and mailbox, then begin your workflow.
HEREDOC

  echo "$prompt_file"
}

# Generate a launcher script for a role
# Usage: squad_prompt_launcher <squad_dir> <role_name> <repo_path> <work_dir> [sprint_file] [model]
squad_prompt_launcher() {
  local squad_dir="$1"
  local role_name="$2"
  local repo_path="$3"
  local work_dir="$4"
  local sprint_file="${5:-}"
  local model="${6:-claude-opus-4-6}"
  local prompt_file="${squad_dir}/prompt-${role_name}.md"
  local launch_file="${squad_dir}/launch-${role_name}.sh"

  cat > "$launch_file" << HEREDOC
#!/usr/bin/env bash
# Auto-generated launcher for ${role_name} agent
cd "${work_dir}"
exec claude --dangerously-skip-permissions --append-system-prompt-file "${prompt_file}" --model "${model}"
HEREDOC

  chmod +x "$launch_file"
  echo "$launch_file"
}

# Generate all prompts and launchers for a session
# Usage: squad_prompt_generate_all <squad_dir> <repo_path> <sprint_file> <model> <roles...>
squad_prompt_generate_all() {
  local squad_dir="$1"
  local repo_path="$2"
  local sprint_file="${3:-}"
  local model="${4:-claude-opus-4-6}"
  shift 4
  local roles=("$@")
  local total=${#roles[@]}

  local _ga_role _ga_workdir _ga_sid _ga_wtpath
  for ((i = 0; i < total; i++)); do
    _ga_role="${roles[$i]}"
    _ga_workdir="$repo_path"

    # Check if worktree exists for this role
    _ga_sid=$(jq -r '.session_id' "${squad_dir}/session.json" 2>/dev/null)
    if [[ -n "$_ga_sid" ]]; then
      _ga_wtpath=$(squad_worktree_path "$_ga_role" "$_ga_sid")
      if [[ -d "$_ga_wtpath" ]]; then
        _ga_workdir="$_ga_wtpath"
      fi
    fi

    # Pass _ga_workdir (worktree path when applicable) for the prompt's "Repository" field
    squad_prompt_generate "$squad_dir" "$_ga_role" "$i" "$_ga_workdir" "$total" "$sprint_file"
    squad_prompt_launcher "$squad_dir" "$_ga_role" "$repo_path" "$_ga_workdir" "$sprint_file" "$model"
  done
}
