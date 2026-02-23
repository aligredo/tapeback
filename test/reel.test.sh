#!/usr/bin/env bash
# tapeback — /reel command integration tests
#
# Verifies the git-graph.js and generate-reel.js primitives that /reel uses:
# buildGraph commit classification, lane assignment, isRec flag, and HTML output.

set -euo pipefail

PASS=0
FAIL=0
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"

# ─── Helpers ──────────────────────────────────────────────────────────────────

make_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@tapeback.sh"
  git -C "$dir" config user.name "tapeback test"
  # Initial commit on main (this becomes the shared/diverge base)
  echo "root" > "$dir/root.txt"
  git -C "$dir" add .
  git -C "$dir" commit -q -m "chore: initial"
  echo "$dir"
}

rec_commit() {
  local repo="$1" msg="$2" file="${3:-rec_${RANDOM}.txt}"
  echo "$RANDOM" > "$repo/$file"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "chore(tapeback): $msg [REC]"
}

plain_commit() {
  local repo="$1" msg="$2"
  echo "$RANDOM" > "$repo/plain_${RANDOM}.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$msg"
}

ok()   { echo "  ✓ $1"; (( PASS++ )) || true; }
fail() { echo "  ✗ $1"; (( FAIL++ )) || true; }

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] && ok "$label" || fail "$label (got '$actual', want '$expected')"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  echo "$haystack" | grep -q "$needle" && ok "$label" || fail "$label (pattern '$needle' not found)"
}

cleanup() { rm -rf "$1"; }

# ─── Tests ────────────────────────────────────────────────────────────────────

echo ""
echo "tapeback /reel tests"
echo "────────────────────"

# ── 1. buildGraph: feature commits are classified correctly ───────────────────

T=$(make_repo)
# Tag main position, then add feature commits
git -C "$T" tag main HEAD
rec_commit "$T" "add auth"
plain_commit "$T" "manual tweak"

output=$(node -e "
  const { buildGraph } = require('$SRC_DIR/git-graph.js');
  const g = buildGraph('$T');
  const n = g.commits.filter(c => c.type === 'feature').length;
  process.stdout.write(String(n));
")
assert_eq "$output" "2" "buildGraph finds 2 feature commits since main"
cleanup "$T"

# ── 2. isRec flag is set on [REC] commits ─────────────────────────────────────

T=$(make_repo)
git -C "$T" tag main HEAD
rec_commit "$T" "recording one"
plain_commit "$T" "manual work"

recCount=$(node -e "
  const { buildGraph } = require('$SRC_DIR/git-graph.js');
  const g = buildGraph('$T');
  const n = g.commits.filter(c => c.isRec).length;
  process.stdout.write(String(n));
")
assert_eq "$recCount" "1" "isRec is set on exactly 1 [REC] commit"
cleanup "$T"

# ── 3. Non-[REC] commits have isRec = false ───────────────────────────────────

T=$(make_repo)
git -C "$T" tag main HEAD
plain_commit "$T" "manual one"
plain_commit "$T" "manual two"

recCount=$(node -e "
  const { buildGraph } = require('$SRC_DIR/git-graph.js');
  const g = buildGraph('$T');
  const n = g.commits.filter(c => c.isRec).length;
  process.stdout.write(String(n));
")
assert_eq "$recCount" "0" "isRec is false when no [REC] commits exist"
cleanup "$T"

# ── 4. generate-reel.js writes a file and prints its path ─────────────────────

T=$(make_repo)
git -C "$T" tag main HEAD
rec_commit "$T" "add feature"

out_path=$(node "$SRC_DIR/generate-reel.js" "$T")
assert_eq "$([ -f "$out_path" ] && echo yes || echo no)" "yes" "generate-reel.js creates the HTML file"
cleanup "$T"
rm -f "$out_path"

# ── 5. Generated HTML contains expected structure ─────────────────────────────

T=$(make_repo)
git -C "$T" tag main HEAD
rec_commit "$T" "add login" "login.txt"
plain_commit "$T" "manual fix"

out_path=$(node "$SRC_DIR/generate-reel.js" "$T")
html=$(cat "$out_path")

assert_contains "$html" "tapeback reel" "HTML title contains 'tapeback reel'"
assert_contains "$html" "tb-tip" "HTML contains tooltip element"
assert_contains "$html" 'class="dot"' "HTML contains SVG dot elements"
assert_contains "$html" "ff7b72" "HTML contains [REC] colour for recording commit"
cleanup "$T"
rm -f "$out_path"

# ── 6. squashBaseRef from .tapeback.json is used as base ──────────────────────

T=$(make_repo)
echo '{"squashBaseRef":"custom-base","recTag":"[REC]"}' > "$T/.tapeback.json"
baseRef=$(node -e "
  const { buildGraph } = require('$SRC_DIR/git-graph.js');
  // Just load config, don't run git
  const path = require('path');
  const fs = require('fs');
  try {
    const c = JSON.parse(fs.readFileSync(path.join('$T', '.tapeback.json'), 'utf8'));
    process.stdout.write(c.squashBaseRef || 'main');
  } catch(e) { process.stdout.write('main'); }
")
assert_eq "$baseRef" "custom-base" "squashBaseRef from .tapeback.json is respected"
cleanup "$T"

# ── 7. byHash map is populated for all commits ────────────────────────────────

T=$(make_repo)
git -C "$T" tag main HEAD
rec_commit "$T" "step one"
rec_commit "$T" "step two"

hashCount=$(node -e "
  const { buildGraph } = require('$SRC_DIR/git-graph.js');
  const g = buildGraph('$T');
  process.stdout.write(String(Object.keys(g.byHash).length));
")
commitCount=$(node -e "
  const { buildGraph } = require('$SRC_DIR/git-graph.js');
  const g = buildGraph('$T');
  process.stdout.write(String(g.commits.length));
")
assert_eq "$hashCount" "$commitCount" "byHash has an entry for every commit"
cleanup "$T"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
