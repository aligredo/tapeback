#!/usr/bin/env bash
# tapeback — hook integration tests
# Creates a real temporary git repo for each test and verifies hook behavior.

set -euo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/plugin/hooks/post-tool-use.sh"
PASS=0
FAIL=0

# ─── Helpers ──────────────────────────────────────────────────────────────────

make_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@tapeback.sh"
  git -C "$dir" config user.name "tapeback test"
  # Initial commit so HEAD exists
  touch "$dir/.gitkeep"
  git -C "$dir" add .
  git -C "$dir" commit -q -m "chore: initial"
  echo "$dir"
}

cleanup() {
  rm -rf "$1"
}

run_hook() {
  local repo="$1"
  local tool="${2:-Write}"
  (
    cd "$repo"
    export CLAUDE_TOOL_NAME="$tool"
    export CLAUDE_TOOL_INPUT_CONTENT="${3:-test agent message}"
    export CLAUDE_SESSION_ID="test-session-123"
    bash "$HOOK"
  )
}

assert_commit_count() {
  local repo="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(git -C "$repo" rev-list --count HEAD)"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ✓ $label"
    (( PASS++ )) || true
  else
    echo "  ✗ $label (expected $expected commits, got $actual)"
    (( FAIL++ )) || true
  fi
}

assert_last_commit_contains() {
  local repo="$1"
  local pattern="$2"
  local label="$3"
  local msg
  msg="$(git -C "$repo" log -1 --pretty=%B)"
  if echo "$msg" | grep -q "$pattern"; then
    echo "  ✓ $label"
    (( PASS++ )) || true
  else
    echo "  ✗ $label (pattern '$pattern' not found in: $msg)"
    (( FAIL++ )) || true
  fi
}

assert_exit_zero() {
  local repo="$1"
  local tool="$2"
  local label="$3"
  local code=0
  run_hook "$repo" "$tool" || code=$?
  if [[ "$code" == "0" ]]; then
    echo "  ✓ $label"
    (( PASS++ )) || true
  else
    echo "  ✗ $label (expected exit 0, got $code)"
    (( FAIL++ )) || true
  fi
}

# ─── Tests ────────────────────────────────────────────────────────────────────

echo ""
echo "tapeback hook tests"
echo "───────────────────"

# Test 1: Hook exits 0 for non-file-modifying tools
T1="$(make_repo)"
assert_exit_zero "$T1" "Bash" "exits 0 for non-modifying tool (Bash)"
assert_commit_count "$T1" 1 "no commit created for non-modifying tool"
cleanup "$T1"

# Test 2: Hook exits 0 even when no files changed
T2="$(make_repo)"
assert_exit_zero "$T2" "Write" "exits 0 when no files changed"
assert_commit_count "$T2" 1 "no commit when nothing staged"
cleanup "$T2"

# Test 3: Hook creates a [REC] commit after a file change
T3="$(make_repo)"
echo "hello" > "$T3/src.txt"
(
  cd "$T3"
  export CLAUDE_TOOL_NAME="Write"
  export CLAUDE_TOOL_INPUT_CONTENT="add greeting file"
  export CLAUDE_SESSION_ID="sess-abc"
  bash "$HOOK"
)
assert_commit_count "$T3" 2 "creates a commit when files changed"
assert_last_commit_contains "$T3" "\[REC\]" "commit subject contains [REC] tag"
assert_last_commit_contains "$T3" "tapeback" "commit subject contains tapeback scope"
assert_last_commit_contains "$T3" "sess-abc" "commit body contains session ID"
cleanup "$T3"

# Test 4: Hook works for Edit tool
T4="$(make_repo)"
echo "edited" > "$T4/file.txt"
(
  cd "$T4"
  export CLAUDE_TOOL_NAME="Edit"
  export CLAUDE_TOOL_INPUT_CONTENT="edit file"
  export CLAUDE_SESSION_ID="unknown"
  bash "$HOOK"
)
assert_commit_count "$T4" 2 "creates a commit for Edit tool"
assert_last_commit_contains "$T4" "\[REC\]" "Edit tool commit has [REC] tag"
cleanup "$T4"

# Test 5: Hook works for MultiEdit tool
T5="$(make_repo)"
echo "multi" > "$T5/a.txt"
echo "edit" > "$T5/b.txt"
(
  cd "$T5"
  export CLAUDE_TOOL_NAME="MultiEdit"
  export CLAUDE_TOOL_INPUT_CONTENT="multi-edit two files"
  export CLAUDE_SESSION_ID="unknown"
  bash "$HOOK"
)
assert_commit_count "$T5" 2 "creates a commit for MultiEdit tool"
cleanup "$T5"

# Test 6: Hook respects custom recTag in .tapeback.json
T6="$(make_repo)"
echo '{"recTag":"[SNAP]","messageStyle":"deterministic","sessionTag":true,"ignore":[]}' > "$T6/.tapeback.json"
echo "snap" > "$T6/snap.txt"
(
  cd "$T6"
  export CLAUDE_TOOL_NAME="Write"
  export CLAUDE_TOOL_INPUT_CONTENT="custom tag test"
  export CLAUDE_SESSION_ID="unknown"
  bash "$HOOK"
)
assert_last_commit_contains "$T6" "\[SNAP\]" "respects custom recTag from .tapeback.json"
cleanup "$T6"

# Test 7: Hook exits 0 even outside a git repo
T7="$(mktemp -d)"
(
  cd "$T7"
  export CLAUDE_TOOL_NAME="Write"
  bash "$HOOK"
) && echo "  ✓ exits 0 outside git repo" && (( PASS++ )) || true
cleanup "$T7"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
