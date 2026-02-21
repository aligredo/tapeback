#!/usr/bin/env bash
# tapeback — /tapeback command integration tests
#
# These tests verify the git primitives that the /tapeback prompt instructs
# Claude to execute. Each test builds a real temporary git repo seeded with
# [REC] commits, then asserts the correct outcomes.

set -euo pipefail

PASS=0
FAIL=0
REC_TAG="[REC]"

# ─── Helpers ──────────────────────────────────────────────────────────────────

make_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@tapeback.sh"
  git -C "$dir" config user.name "tapeback test"
  echo "$dir"
}

# Create a [REC] commit in the repo
rec_commit() {
  local repo="$1"
  local msg="$2"
  local file="${3:-file_${RANDOM}.txt}"
  echo "$RANDOM" > "$repo/$file"
  git -C "$repo" add "$file"
  git -C "$repo" commit -q \
    -m "chore(tapeback): $msg $REC_TAG" \
    -m "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --allow-empty
}

# Create a regular (non-REC) commit
plain_commit() {
  local repo="$1"
  local msg="$2"
  echo "$RANDOM" > "$repo/plain_${RANDOM}.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$msg" --allow-empty
}

ok() {
  echo "  ✓ $1"
  (( PASS++ )) || true
}

fail() {
  echo "  ✗ $1"
  (( FAIL++ )) || true
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] && ok "$label" || fail "$label (got '$actual', want '$expected')"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  echo "$haystack" | grep -q "$needle" && ok "$label" || fail "$label (pattern '$needle' not found)"
}

assert_file_exists() {
  [[ -f "$1" ]] && ok "$2" || fail "$2 (file not found: $1)"
}

assert_file_not_exists() {
  [[ ! -f "$1" ]] && ok "$2" || fail "$2 (file unexpectedly exists: $1)"
}

cleanup() { rm -rf "$1"; }

# ─── Helper: find Nth [REC] commit hash (1-based) ─────────────────────────────
# Mirrors the logic Claude is instructed to run in Step 2.

nth_rec_hash() {
  local repo="$1"
  local n="$2"
  git -C "$repo" log --oneline --grep='\[REC\]' | sed -n "${n}p" | awk '{print $1}'
}

rec_count() {
  local repo="$1"
  git -C "$repo" log --oneline --grep='\[REC\]' | wc -l | tr -d ' '
}

# ─── Tests ────────────────────────────────────────────────────────────────────

echo ""
echo "tapeback /tapeback tests"
echo "────────────────────────"

# ── 1. Find [REC] commits ──────────────────────────────────────────────────────

T=$(make_repo)
plain_commit "$T" "chore: initial"
rec_commit "$T" "add auth middleware"
rec_commit "$T" "fix token expiry"
rec_commit "$T" "add user model"

count=$(rec_count "$T")
assert_eq "$count" "3" "detects correct number of [REC] commits"

hash1=$(nth_rec_hash "$T" 1)
assert_contains "$(git -C "$T" log -1 --pretty=%s "$hash1")" "\[REC\]" "1st [REC] commit subject has tag"

hash3=$(nth_rec_hash "$T" 3)
assert_contains "$(git -C "$T" log -1 --pretty=%s "$hash3")" "\[REC\]" "3rd [REC] commit subject has tag"
cleanup "$T"

# ── 2. git reset --hard rolls back to target ──────────────────────────────────

T=$(make_repo)
plain_commit "$T" "chore: initial"

# Create a file in recording 1, then modify it in recording 2
echo "v1" > "$T/src.txt"
git -C "$T" add -A && git -C "$T" commit -q -m "chore(tapeback): add src $REC_TAG"

echo "v2" > "$T/src.txt"
git -C "$T" add -A && git -C "$T" commit -q -m "chore(tapeback): update src $REC_TAG"

target=$(nth_rec_hash "$T" 2)   # 2nd most recent = recording 1
git -C "$T" reset --hard "$target" > /dev/null

content="$(cat "$T/src.txt")"
assert_eq "$content" "v1" "hard reset restores file to state at target recording"

remaining=$(rec_count "$T")
assert_eq "$remaining" "1" "only 1 [REC] commit remains after tapeback"
cleanup "$T"

# ── 3. Tapeback N=1 (default): removes only the last recording ────────────────

T=$(make_repo)
plain_commit "$T" "chore: initial"
rec_commit "$T" "recording one"
rec_commit "$T" "recording two"
rec_commit "$T" "recording three"

target=$(nth_rec_hash "$T" 2)   # N=1 means rewind to 2nd most recent (one before latest)
git -C "$T" reset --hard "$target" > /dev/null

remaining=$(rec_count "$T")
assert_eq "$remaining" "2" "tapeback N=1 leaves 2 recordings"
assert_contains "$(git -C "$T" log -1 --pretty=%s)" "recording two" "HEAD is now recording two"
cleanup "$T"

# ── 4. Tapeback N=3: removes last 3 recordings ────────────────────────────────

T=$(make_repo)
plain_commit "$T" "chore: initial"
rec_commit "$T" "rec one"
rec_commit "$T" "rec two"
rec_commit "$T" "rec three"
rec_commit "$T" "rec four"

# N=3 → target is the 4th [REC] from top (i.e. index N+1)
target=$(nth_rec_hash "$T" 4)
git -C "$T" reset --hard "$target" > /dev/null

remaining=$(rec_count "$T")
assert_eq "$remaining" "1" "tapeback N=3 leaves 1 recording"
assert_contains "$(git -C "$T" log -1 --pretty=%s)" "rec one" "HEAD is now rec one"
cleanup "$T"

# ── 5. Hash-based tapeback targets correct commit ─────────────────────────────

T=$(make_repo)
plain_commit "$T" "chore: initial"
rec_commit "$T" "alpha"
rec_commit "$T" "beta"
rec_commit "$T" "gamma"

alpha_hash=$(nth_rec_hash "$T" 3)   # oldest = alpha
git -C "$T" reset --hard "$alpha_hash" > /dev/null

assert_contains "$(git -C "$T" log -1 --pretty=%s)" "alpha" "hash-based tapeback lands on correct commit"
cleanup "$T"

# ── 6. git stash preserves uncommitted changes before tapeback ────────────────

T=$(make_repo)
plain_commit "$T" "chore: initial"
rec_commit "$T" "baseline"
rec_commit "$T" "after baseline"

# Uncommitted change
echo "dirty" > "$T/dirty.txt"
git -C "$T" add "$T/dirty.txt"

# Stash (as the prompt instructs for choice 1)
git -C "$T" stash push -q -m "tapeback: pre-tapeback stash"

assert_file_not_exists "$T/dirty.txt" "stash removes staged file from working tree"

# Rollback
target=$(nth_rec_hash "$T" 2)
git -C "$T" reset --hard "$target" > /dev/null

# Restore stash
git -C "$T" stash pop -q

assert_file_exists "$T/dirty.txt" "git stash pop restores the file after tapeback"
assert_eq "$(cat "$T/dirty.txt")" "dirty" "stash pop restores correct file content"
cleanup "$T"

# ── 7. Hard reset discards uncommitted changes (abandon flow) ─────────────────

T=$(make_repo)
plain_commit "$T" "chore: initial"
rec_commit "$T" "clean state"
rec_commit "$T" "after clean"

echo "throwaway" > "$T/throwaway.txt"
git -C "$T" add "$T/throwaway.txt"

target=$(nth_rec_hash "$T" 2)
git -C "$T" reset --hard "$target" > /dev/null

assert_file_not_exists "$T/throwaway.txt" "hard reset discards uncommitted staged changes"
cleanup "$T"

# ── 8. Non-REC commits are skipped when counting ─────────────────────────────

T=$(make_repo)
plain_commit "$T" "chore: initial"
rec_commit "$T" "rec one"
plain_commit "$T" "feat: something manual"
rec_commit "$T" "rec two"
plain_commit "$T" "docs: readme"

count=$(rec_count "$T")
assert_eq "$count" "2" "non-[REC] commits are not counted as recordings"

hash=$(nth_rec_hash "$T" 1)
assert_contains "$(git -C "$T" log -1 --pretty=%s "$hash")" "rec two" "most recent [REC] is rec two despite interleaved commits"
cleanup "$T"

# ── 9. Timestamp field is present in [REC] commit bodies ─────────────────────

T=$(make_repo)
plain_commit "$T" "chore: initial"
rec_commit "$T" "timestamped recording"

body="$(git -C "$T" log -1 --pretty=%B)"
assert_contains "$body" "Timestamp:" "commit body contains Timestamp field"
assert_contains "$body" "\[REC\]" "commit subject contains [REC] tag"
cleanup "$T"

# ── 10. Rollback is a no-op when 0 recordings exist ─────────────────────────

T=$(make_repo)
plain_commit "$T" "chore: initial"
plain_commit "$T" "feat: something"

count=$(rec_count "$T")
assert_eq "$count" "0" "correctly reports 0 recordings when none exist"
# (Claude is instructed to stop and tell the user — no git commands run)
cleanup "$T"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
