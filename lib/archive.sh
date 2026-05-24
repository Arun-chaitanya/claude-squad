#!/usr/bin/env bash
# lib/archive.sh — Suspend & resume squad sessions.
#
# squad stop archives .squad/<name> to .squad-archive/<name>-<timestamp>/
# instead of discarding it; squad resume <name> restores the most recent
# archive matching that name and respawns the previously-alive agents.
#
# A small meta.json next to the archived runtime captures the original squad
# name, archive timestamp, agent count, and (optional) sprint description so
# `squad archive list` can render a useful summary without parsing the full
# session.json.
#
# Retention: archives older than $SQUAD_ARCHIVE_RETENTION_DAYS (default 30)
# are pruned lazily on stop/resume, or eagerly via `squad archive prune`.

: "${SQUAD_ARCHIVE_RETENTION_DAYS:=30}"

# Per-repo archive root.
# Usage: squad_archive_dir <repo_path>
squad_archive_dir() {
  echo "${1}/.squad-archive"
}

# Move .squad/<name> into the archive root with a timestamp suffix.
# Returns the archive path on stdout. Records meta.json for `archive list`.
# Usage: squad_archive_stash <repo_path> <squad_name>
squad_archive_stash() {
  local repo_path="$1"
  local name="$2"
  local src="${repo_path}/.squad/${name}"
  local arch_root
  arch_root=$(squad_archive_dir "$repo_path")

  if [[ ! -d "$src" ]]; then
    echo "Error: no runtime to archive at ${src}" >&2
    return 1
  fi
  if [[ ! -f "${src}/session.json" ]]; then
    echo "Error: ${src} has no session.json — refusing to archive" >&2
    return 1
  fi

  mkdir -p "$arch_root"
  local ts
  ts=$(date -u +"%Y%m%dT%H%M%SZ")
  local dest="${arch_root}/${name}-${ts}"

  # Avoid collision in the unlikely event of two same-second archives.
  local suffix=1
  while [[ -e "$dest" ]]; do
    dest="${arch_root}/${name}-${ts}-${suffix}"
    suffix=$((suffix + 1))
  done

  mv "$src" "$dest"

  # Pull out a useful one-line description (sprint title or "no sprint").
  local sprint_file desc=""
  sprint_file=$(jq -r '.sprint_file // ""' "${dest}/session.json" 2>/dev/null)
  if [[ -n "$sprint_file" && "$sprint_file" != "null" && -f "$sprint_file" ]]; then
    desc=$(head -n 1 "$sprint_file" | sed 's/^# *//' | head -c 120)
  fi

  local agent_count session_id
  agent_count=$(jq -r '[.agents[] | select(.status == "alive")] | length' \
    "${dest}/session.json" 2>/dev/null || echo "0")
  session_id=$(jq -r '.session_id // ""' "${dest}/session.json" 2>/dev/null)

  jq -n \
    --arg name "$name" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg session_id "$session_id" \
    --arg sprint "$sprint_file" \
    --arg desc "$desc" \
    --argjson agents "$agent_count" \
    '{name:$name, archived_at:$ts, session_id:$session_id,
      sprint_file:$sprint, description:$desc, agent_count:$agents}' \
    > "${dest}/meta.json"

  echo "$dest"
}

# List all archives, newest first. One TSV line per archive:
#   archive_dir<TAB>name<TAB>archived_at<TAB>age_human<TAB>agents<TAB>description
# Usage: squad_archive_list <repo_path>
squad_archive_list() {
  local repo_path="$1"
  local arch_root
  arch_root=$(squad_archive_dir "$repo_path")
  [[ -d "$arch_root" ]] || return 0

  local now
  now=$(date +%s)

  # Build "<mtime> <dir>" lines, sort, then emit. Using a portable stat call
  # per directory keeps this working on macOS (BSD stat) and Linux (GNU stat).
  local dir name archived_at desc agents mtime age_h
  local sorted
  sorted=$(
    for dir in "$arch_root"/*/; do
      [[ -d "$dir" ]] || continue
      dir="${dir%/}"
      mtime=$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null || echo 0)
      printf '%s\t%s\n' "$mtime" "$dir"
    done | sort -rn
  )

  while IFS=$'\t' read -r mtime dir; do
    [[ -n "$dir" ]] || continue
    [[ -f "${dir}/meta.json" ]] || continue

    name=$(jq -r '.name // "?"' "${dir}/meta.json" 2>/dev/null)
    archived_at=$(jq -r '.archived_at // "?"' "${dir}/meta.json" 2>/dev/null)
    desc=$(jq -r '.description // ""' "${dir}/meta.json" 2>/dev/null)
    agents=$(jq -r '.agent_count // 0' "${dir}/meta.json" 2>/dev/null)

    age_h=$(_squad_archive_age_human $((now - mtime)))

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$dir" "$name" "$archived_at" "$age_h" "$agents" "$desc"
  done <<< "$sorted"
}

# Resolve a squad name (or full archive basename) to the latest matching
# archive directory. Echoes the path on stdout; returns 1 if no match.
# Usage: squad_archive_latest <repo_path> <name_or_basename>
squad_archive_latest() {
  local repo_path="$1"
  local query="$2"
  local arch_root
  arch_root=$(squad_archive_dir "$repo_path")
  [[ -d "$arch_root" ]] || return 1

  # Exact basename match wins (so the user can pin by `default-20260524T091500Z`).
  if [[ -d "${arch_root}/${query}" ]]; then
    echo "${arch_root}/${query}"
    return 0
  fi

  # Otherwise pick newest archive whose meta.json `name` equals the query.
  local dir match=""
  local match_mtime=0 mt
  for dir in "$arch_root"/*/; do
    dir="${dir%/}"
    [[ -f "${dir}/meta.json" ]] || continue
    local meta_name
    meta_name=$(jq -r '.name // ""' "${dir}/meta.json" 2>/dev/null)
    [[ "$meta_name" == "$query" ]] || continue
    mt=$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null || echo 0)
    if [[ "$mt" -gt "$match_mtime" ]]; then
      match="$dir"
      match_mtime="$mt"
    fi
  done

  if [[ -z "$match" ]]; then
    return 1
  fi
  echo "$match"
}

# Move an archive back to .squad/<name>. If a live runtime already exists at
# the target, refuse — the caller should stop the current squad first.
# Usage: squad_archive_restore <repo_path> <archive_dir> [target_name]
squad_archive_restore() {
  local repo_path="$1"
  local archive_dir="$2"
  local target_name="${3:-}"

  if [[ ! -d "$archive_dir" ]]; then
    echo "Error: archive not found: ${archive_dir}" >&2
    return 1
  fi

  if [[ -z "$target_name" ]]; then
    target_name=$(jq -r '.name // ""' "${archive_dir}/meta.json" 2>/dev/null)
    if [[ -z "$target_name" || "$target_name" == "null" ]]; then
      echo "Error: archive ${archive_dir} has no name in meta.json; pass an explicit target_name" >&2
      return 1
    fi
  fi

  local dest="${repo_path}/.squad/${target_name}"
  if [[ -e "$dest" ]]; then
    echo "Error: ${dest} already exists — stop the current squad first" >&2
    return 1
  fi

  mkdir -p "${repo_path}/.squad"
  mv "$archive_dir" "$dest"
  echo "$dest"
}

# Delete archives older than $SQUAD_ARCHIVE_RETENTION_DAYS days. Prints one
# line per pruned dir. Safe to call lazily on every stop/resume.
# Usage: squad_archive_prune <repo_path> [days]
squad_archive_prune() {
  local repo_path="$1"
  local days="${2:-$SQUAD_ARCHIVE_RETENTION_DAYS}"
  local arch_root
  arch_root=$(squad_archive_dir "$repo_path")
  [[ -d "$arch_root" ]] || return 0

  local cutoff now mt dir
  now=$(date +%s)
  cutoff=$((now - days * 86400))

  for dir in "$arch_root"/*/; do
    [[ -d "$dir" ]] || continue
    dir="${dir%/}"
    mt=$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null || echo "$now")
    if [[ "$mt" -lt "$cutoff" ]]; then
      rm -rf "$dir"
      echo "$dir"
    fi
  done
}

# Render seconds → "3d 4h", "27m", "12s". Used by squad_archive_list.
_squad_archive_age_human() {
  local s="$1"
  local d=$((s / 86400))
  local h=$(((s % 86400) / 3600))
  local m=$(((s % 3600) / 60))
  if [[ "$d" -gt 0 ]]; then echo "${d}d ${h}h"; return; fi
  if [[ "$h" -gt 0 ]]; then echo "${h}h ${m}m"; return; fi
  if [[ "$m" -gt 0 ]]; then echo "${m}m"; return; fi
  echo "${s}s"
}
