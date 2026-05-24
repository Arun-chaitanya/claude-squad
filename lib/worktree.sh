#!/usr/bin/env bash
# lib/worktree.sh — Git worktree management for agent isolation
# Each agent gets its own worktree so they can work on code simultaneously
# without filesystem conflicts.

SQUAD_WORKTREE_DIR="${HOME}/.claude-squad/worktrees"

# Create a worktree for an agent
# Usage: squad_worktree_create <repo_path> <role_name> <session_id>
# Returns: the worktree path
squad_worktree_create() {
  local repo_path="$1"
  local role_name="$2"
  local session_id="$3"
  local branch_name="squad/${session_id}/${role_name}"
  local worktree_path="${SQUAD_WORKTREE_DIR}/${session_id}/${role_name}"

  mkdir -p "$(dirname "$worktree_path")"

  # Get current HEAD commit
  local head_commit
  head_commit=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null)

  if [[ -z "$head_commit" ]]; then
    # Repo has no commits — initialize with an empty commit
    git -C "$repo_path" commit --allow-empty -m "Initial commit for squad" >/dev/null 2>&1
    head_commit=$(git -C "$repo_path" rev-parse HEAD)
  fi

  # Create the worktree with a new branch
  if ! git -C "$repo_path" worktree add -b "$branch_name" "$worktree_path" "$head_commit" >/dev/null 2>&1; then
    # Branch might already exist — try without -b
    if ! git -C "$repo_path" worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1; then
      echo "Error: failed to create worktree for $role_name" >&2
      return 1
    fi
  fi

  echo "$worktree_path"
}

# Remove a worktree for an agent
# Usage: squad_worktree_remove <repo_path> <role_name> <session_id>
squad_worktree_remove() {
  local repo_path="$1"
  local role_name="$2"
  local session_id="$3"
  local branch_name="squad/${session_id}/${role_name}"
  local worktree_path="${SQUAD_WORKTREE_DIR}/${session_id}/${role_name}"

  if [[ -d "$worktree_path" ]]; then
    git -C "$repo_path" worktree remove "$worktree_path" --force 2>/dev/null
  fi

  # Clean up the branch
  git -C "$repo_path" branch -D "$branch_name" 2>/dev/null
}

# Remove all worktrees for a session
# Usage: squad_worktree_cleanup <repo_path> <session_id>
squad_worktree_cleanup() {
  local repo_path="$1"
  local session_id="$2"
  local session_dir="${SQUAD_WORKTREE_DIR}/${session_id}"

  if [[ -d "$session_dir" ]]; then
    # Prune stale worktrees first
    git -C "$repo_path" worktree prune 2>/dev/null

    # Remove each worktree directory
    local _wt_role
    for wt_dir in "$session_dir"/*/; do
      if [[ -d "$wt_dir" ]]; then
        _wt_role=$(basename "$wt_dir")
        squad_worktree_remove "$repo_path" "$_wt_role" "$session_id"
      fi
    done

    rm -rf "$session_dir"
  fi

  # Clean up any remaining squad branches for this session
  git -C "$repo_path" branch --list "squad/${session_id}/*" | while read -r branch; do
    git -C "$repo_path" branch -D "$branch" 2>/dev/null
  done
}

# Get the worktree path for an agent
# Usage: squad_worktree_path <role_name> <session_id>
squad_worktree_path() {
  local role_name="$1"
  local session_id="$2"
  echo "${SQUAD_WORKTREE_DIR}/${session_id}/${role_name}"
}

# Check if a worktree exists
# Usage: squad_worktree_exists <role_name> <session_id>
squad_worktree_exists() {
  local role_name="$1"
  local session_id="$2"
  local worktree_path="${SQUAD_WORKTREE_DIR}/${session_id}/${role_name}"
  [[ -d "$worktree_path" ]]
}

# Get the diff of changes in a worktree
# Usage: squad_worktree_diff <role_name> <session_id>
squad_worktree_diff() {
  local role_name="$1"
  local session_id="$2"
  local worktree_path="${SQUAD_WORKTREE_DIR}/${session_id}/${role_name}"

  if [[ -d "$worktree_path" ]]; then
    # Show both tracked changes and new untracked files
    git -C "$worktree_path" add -N . 2>/dev/null
    git -C "$worktree_path" diff 2>/dev/null
  fi
}

# Commit all changes in a worktree
# Usage: squad_worktree_commit <role_name> <session_id> <message>
squad_worktree_commit() {
  local role_name="$1"
  local session_id="$2"
  local message="$3"
  local worktree_path="${SQUAD_WORKTREE_DIR}/${session_id}/${role_name}"

  if [[ -d "$worktree_path" ]]; then
    git -C "$worktree_path" add -A
    git -C "$worktree_path" commit -m "$message" 2>/dev/null
  fi
}

# Merge a worktree branch back into the main branch
# Usage: squad_worktree_merge <repo_path> <role_name> <session_id> <target_branch>
squad_worktree_merge() {
  local repo_path="$1"
  local role_name="$2"
  local session_id="$3"
  local target_branch="${4:-main}"
  local branch_name="squad/${session_id}/${role_name}"

  git -C "$repo_path" checkout "$target_branch" 2>/dev/null
  git -C "$repo_path" merge "$branch_name" --no-ff -m "Merge squad/${role_name} work" 2>/dev/null
}

# List all active worktrees for a session
# Usage: squad_worktree_list <session_id>
squad_worktree_list() {
  local session_id="$1"
  local session_dir="${SQUAD_WORKTREE_DIR}/${session_id}"

  if [[ -d "$session_dir" ]]; then
    local _ls_role _ls_state
    for wt_dir in "$session_dir"/*/; do
      if [[ -d "$wt_dir" ]]; then
        _ls_role=$(basename "$wt_dir")
        _ls_state="clean"
        if [[ -n "$(git -C "$wt_dir" status --porcelain 2>/dev/null)" ]]; then
          _ls_state="dirty"
        fi
        echo "${_ls_role}: ${wt_dir} (${_ls_state})"
      fi
    done
  fi
}
