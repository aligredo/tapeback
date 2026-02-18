#!/usr/bin/env bash
# tapeback — post-tool-use hook
# Fires after every Claude Code Write/Edit/MultiEdit tool call.
# Commits any file changes with a [REC] tag so the session is always rewindable.
# CRITICAL: This script must ALWAYS exit 0. It must never block Claude.

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────

HOOK_NAME="tapeback"
DEFAULT_REC_TAG="[REC]"
DEFAULT_MESSAGE_STYLE="deterministic"
DEFAULT_AI_TIMEOUT_MS=5000
DEFAULT_SESSION_TAG="true"
DEFAULT_IGNORE='["*.env","*.log",".tapeback.json"]'

# ─── Safety wrapper — ensure we always exit 0 ─────────────────────────────────

tapeback_main() {
  # Only act on file-modifying tools
  local tool_name="${CLAUDE_TOOL_NAME:-}"
  case "$tool_name" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
  esac

  # Must be inside a git repo
  if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    exit 0
  fi

  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"

  # ─── Load config ────────────────────────────────────────────────────────────

  local config_file="$repo_root/.tapeback.json"
  local rec_tag="$DEFAULT_REC_TAG"
  local message_style="$DEFAULT_MESSAGE_STYLE"
  local ai_timeout_ms="$DEFAULT_AI_TIMEOUT_MS"
  local session_tag="$DEFAULT_SESSION_TAG"
  local ignore_patterns="$DEFAULT_IGNORE"

  if [[ -f "$config_file" ]] && command -v node > /dev/null 2>&1; then
    rec_tag="$(node -e "
      try {
        const c = require('$config_file');
        process.stdout.write(c.recTag || '$DEFAULT_REC_TAG');
      } catch(e) { process.stdout.write('$DEFAULT_REC_TAG'); }
    " 2>/dev/null || echo "$DEFAULT_REC_TAG")"

    message_style="$(node -e "
      try {
        const c = require('$config_file');
        process.stdout.write(c.messageStyle || '$DEFAULT_MESSAGE_STYLE');
      } catch(e) { process.stdout.write('$DEFAULT_MESSAGE_STYLE'); }
    " 2>/dev/null || echo "$DEFAULT_MESSAGE_STYLE")"

    ai_timeout_ms="$(node -e "
      try {
        const c = require('$config_file');
        process.stdout.write(String(c.aiTimeoutMs || $DEFAULT_AI_TIMEOUT_MS));
      } catch(e) { process.stdout.write('$DEFAULT_AI_TIMEOUT_MS'); }
    " 2>/dev/null || echo "$DEFAULT_AI_TIMEOUT_MS")"

    session_tag="$(node -e "
      try {
        const c = require('$config_file');
        process.stdout.write(c.sessionTag === false ? 'false' : 'true');
      } catch(e) { process.stdout.write('true'); }
    " 2>/dev/null || echo "true")"

    ignore_patterns="$(node -e "
      try {
        const c = require('$config_file');
        process.stdout.write(JSON.stringify(c.ignore || []));
      } catch(e) { process.stdout.write('[]'); }
    " 2>/dev/null || echo "[]")"
  fi

  # ─── Stage changes (respecting ignore patterns) ─────────────────────────────

  # Build excludes for git add
  local excludes=()
  if command -v node > /dev/null 2>&1; then
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] && excludes+=(":!$pattern")
    done < <(node -e "
      try {
        const p = JSON.parse('$ignore_patterns');
        p.forEach(x => console.log(x));
      } catch(e) {}
    " 2>/dev/null)
  fi

  cd "$repo_root"

  if [[ ${#excludes[@]} -gt 0 ]]; then
    git add -A -- "${excludes[@]}" 2>/dev/null || git add -A 2>/dev/null || true
  else
    git add -A 2>/dev/null || true
  fi

  # Nothing staged? Nothing to record.
  if git diff --cached --quiet 2>/dev/null; then
    exit 0
  fi

  # ─── Gather commit metadata ──────────────────────────────────────────────────

  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local session_id="${CLAUDE_SESSION_ID:-unknown}"

  # Changed files with stat
  local changed_files
  changed_files="$(git diff --cached --stat 2>/dev/null | head -20 || echo "  (unable to stat)")"

  # First 100 chars of the agent message that triggered this
  local agent_message="${CLAUDE_TOOL_INPUT_CONTENT:-}"
  agent_message="${agent_message:0:100}"

  # File names only (for deterministic fallback headline)
  local file_names
  file_names="$(git diff --cached --name-only 2>/dev/null | head -5 | tr '\n' ' ' | sed 's/ $//' || echo "files")"

  # ─── Generate headline ───────────────────────────────────────────────────────

  local headline=""

  if [[ "$message_style" == "ai" ]] && command -v claude > /dev/null 2>&1; then
    local ai_timeout_secs=$(( (ai_timeout_ms + 999) / 1000 ))
    local diff_stat
    diff_stat="$(git diff --cached --stat 2>/dev/null | tail -1 || echo "")"

    local prompt="Generate a single concise conventional commit headline (max 72 chars, no quotes) \
describing these code changes. Use imperative mood. Examples: 'add JWT middleware', \
'fix token expiry validation', 'extract auth helper functions'. \
Changed files: $file_names. Diff summary: $diff_stat. \
Agent instruction: ${agent_message:0:200}. \
Output ONLY the headline text, nothing else."

    headline="$(timeout "$ai_timeout_secs" claude -p "$prompt" 2>/dev/null | head -1 | tr -d '"' || true)"

    # Validate: must be non-empty and reasonably short
    if [[ -z "$headline" ]] || [[ ${#headline} -gt 100 ]]; then
      headline=""
    fi
  fi

  # Deterministic fallback
  if [[ -z "$headline" ]]; then
    headline="edit $file_names"
  fi

  # ─── Build commit message ────────────────────────────────────────────────────

  local subject="chore($HOOK_NAME): $headline $rec_tag"

  local body=""
  if [[ -n "$agent_message" ]]; then
    body+="Agent message: \"$agent_message\"\n"
  fi

  body+="Changed files:\n$changed_files\n"
  body+="\nTimestamp: $timestamp"

  if [[ "$session_tag" == "true" ]]; then
    body+="\nSession: $session_id"
  fi

  # ─── Commit ──────────────────────────────────────────────────────────────────

  git commit \
    --no-verify \
    -m "$subject" \
    -m "$(printf '%b' "$body")" \
    > /dev/null 2>&1 || true
}

# Run everything inside the safety wrapper — always exit 0
tapeback_main || true
exit 0
