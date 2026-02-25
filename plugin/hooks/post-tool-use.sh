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
  # ─── Read hook input (Claude Code sends JSON via stdin) ─────────────────────

  local stdin_data=""
  if [[ ! -t 0 ]]; then
    stdin_data="$(cat 2>/dev/null)" || stdin_data=""
  fi

  local tool_name="" hook_session_id="unknown" input_content=""

  if command -v node > /dev/null 2>&1 && [[ -n "$stdin_data" ]]; then
    local _idx=0
    while IFS= read -r _line; do
      case $_idx in
        0) tool_name="$_line" ;;
        1) hook_session_id="$_line" ;;
        2) input_content="$_line" ;;
      esac
      (( _idx++ )) || true
    done < <(printf '%s' "$stdin_data" | node -e "
      const c = [];
      process.stdin.on('data', d => c.push(d));
      process.stdin.on('end', () => {
        try {
          const o = JSON.parse(c.join(''));
          const ti = o.tool_input || {};
          const s = v => String(v || '').replace(/[\n\r]/g, ' ');
          console.log(s(o.tool_name));
          console.log(s(o.session_id));
          console.log(s(ti.content || ti.new_string || '').slice(0, 100));
        } catch(e) { console.log(''); console.log('unknown'); console.log(''); }
      });
    " 2>/dev/null || { echo; echo "unknown"; echo; })
  fi

  # Only act on file-modifying tools
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
  # SECURITY: config values are passed via environment variables into node -e,
  # never interpolated directly into JS source strings. This prevents code
  # injection via a maliciously crafted .tapeback.json path or content.

  local config_file="$repo_root/.tapeback.json"
  local rec_tag="$DEFAULT_REC_TAG"
  local message_style="$DEFAULT_MESSAGE_STYLE"
  local ai_timeout_ms="$DEFAULT_AI_TIMEOUT_MS"
  local session_tag="$DEFAULT_SESSION_TAG"
  local ignore_patterns="$DEFAULT_IGNORE"

  if [[ -f "$config_file" ]] && command -v node > /dev/null 2>&1; then
    rec_tag="$(TAPEBACK_CONFIG="$config_file" TAPEBACK_DEFAULT="$DEFAULT_REC_TAG" \
      node -e "
        try {
          const c = require(process.env.TAPEBACK_CONFIG);
          process.stdout.write(c.recTag || process.env.TAPEBACK_DEFAULT);
        } catch(e) { process.stdout.write(process.env.TAPEBACK_DEFAULT); }
      " 2>/dev/null || echo "$DEFAULT_REC_TAG")"

    message_style="$(TAPEBACK_CONFIG="$config_file" TAPEBACK_DEFAULT="$DEFAULT_MESSAGE_STYLE" \
      node -e "
        try {
          const c = require(process.env.TAPEBACK_CONFIG);
          process.stdout.write(c.messageStyle || process.env.TAPEBACK_DEFAULT);
        } catch(e) { process.stdout.write(process.env.TAPEBACK_DEFAULT); }
      " 2>/dev/null || echo "$DEFAULT_MESSAGE_STYLE")"

    ai_timeout_ms="$(TAPEBACK_CONFIG="$config_file" TAPEBACK_DEFAULT="$DEFAULT_AI_TIMEOUT_MS" \
      node -e "
        try {
          const c = require(process.env.TAPEBACK_CONFIG);
          process.stdout.write(String(c.aiTimeoutMs || process.env.TAPEBACK_DEFAULT));
        } catch(e) { process.stdout.write(process.env.TAPEBACK_DEFAULT); }
      " 2>/dev/null || echo "$DEFAULT_AI_TIMEOUT_MS")"

    session_tag="$(TAPEBACK_CONFIG="$config_file" \
      node -e "
        try {
          const c = require(process.env.TAPEBACK_CONFIG);
          process.stdout.write(c.sessionTag === false ? 'false' : 'true');
        } catch(e) { process.stdout.write('true'); }
      " 2>/dev/null || echo "true")"

    ignore_patterns="$(TAPEBACK_CONFIG="$config_file" \
      node -e "
        try {
          const c = require(process.env.TAPEBACK_CONFIG);
          process.stdout.write(JSON.stringify(c.ignore || []));
        } catch(e) { process.stdout.write('[]'); }
      " 2>/dev/null || echo "[]")"
  fi

  # ─── Stage changes (respecting ignore patterns) ─────────────────────────────
  # SECURITY: ignore_patterns JSON is passed via stdin, not interpolated into JS.

  local excludes=()
  if command -v node > /dev/null 2>&1; then
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] && excludes+=(":!$pattern")
    done < <(printf '%s' "$ignore_patterns" | node -e "
      const chunks = [];
      process.stdin.on('data', d => chunks.push(d));
      process.stdin.on('end', () => {
        try {
          const p = JSON.parse(chunks.join(''));
          if (Array.isArray(p)) p.forEach(x => process.stdout.write(x + '\n'));
        } catch(e) {}
      });
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

  local session_id
  session_id="$(printf '%s' "${hook_session_id:-unknown}" \
    | tr -cd '[:print:]' | head -c 128)"
  [[ -z "$session_id" ]] && session_id="unknown"

  local agent_message
  agent_message="$(printf '%s' "$input_content" \
    | tr -cd '[:print:] \t' | head -c 100)"

  # Changed files with stat
  local changed_files
  changed_files="$(git diff --cached --stat 2>/dev/null | head -20 || echo "  (unable to stat)")"

  # File names (up to 5, for generate-headline.js)
  local file_names_raw
  file_names_raw="$(git diff --cached --name-only 2>/dev/null | head -5 || true)"

  # Diff stat summary (last line)
  local diff_stat
  diff_stat="$(git diff --cached --stat 2>/dev/null | tail -1 || true)"

  # ─── Generate headline via src/generate-headline.js ───────────────────────

  local headline=""
  local script_dir generator
  # Installed: .claude/hooks/ → .claude/src/
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  generator="$script_dir/src/generate-headline.js"
  # Source tree fallback: plugin/hooks/ → repo root src/
  if [[ ! -f "$generator" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    generator="$script_dir/src/generate-headline.js"
  fi

  if command -v node > /dev/null 2>&1 && [[ -f "$generator" ]]; then
    # Pass file names as individual arguments (safe — no word splitting issues)
    local file_args=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && file_args+=("$f")
    done <<< "$file_names_raw"

    headline="$(node "$generator" \
      "$message_style" \
      "$ai_timeout_ms" \
      "$diff_stat" \
      "$agent_message" \
      "${file_args[@]+"${file_args[@]}"}" \
      2>/dev/null || true)"
  fi

  # Final fallback if node/script unavailable or returned empty
  if [[ -z "$headline" ]]; then
    local file_names_inline
    file_names_inline="$(printf '%s' "$file_names_raw" | tr '\n' ' ' | sed 's/ $//')"
    headline="edit ${file_names_inline:-files}"
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
