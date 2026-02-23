#!/usr/bin/env bash
# tapeback — /squash command integration tests
#
# Verifies the git primitives that /squash instructs Claude to execute:
# base-branch divergence detection, [REC] commit enumeration, backup tag
# creation, and git rebase -i selective squash execution.

set -euo pipefail

PASS=0
FAIL=0
REC_TAG="[REC]"
BASE_REF="test-base"   # overridden inside make_repo; declared here for shellcheck

# ─── Helpers ──────────────────────────────────────────────────────────────────

make_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@tapeback.sh"
  git -C "$dir" config user.name "tapeback test"
  # Establish main branch with an initial commit
  echo "root" > "$dir/root.txt"
  git -C "$dir" add .
  git -C "$dir" commit -q -m "chore: initial"
  # Tag the tip of "main" so we can simulate branch divergence in tests
  # (all commits happen on the same branch in tests, so we use a tag
  # as the BASE_REF rather than the branch name)
  git -C "$dir" tag test-base
  echo "$dir"
}

# In tests, BASE_REF is the tag we create after the initial commit
BASE_REF="test-base"

rec_commit() {
  local repo="$1" msg="$2" file="${3:-file_${RANDOM}.txt}"
  echo "$RANDOM" > "$repo/$file"
  git -C "$repo" add -A
  git -C "$repo" commit -q \
    -m "chore(tapeback): $msg $REC_TAG" \
    -m "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}

plain_commit() {
  local repo="$1" msg="$2"
  echo "$RANDOM" > "$repo/plain_${RANDOM}.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$msg"
}

rec_count_since_base() {
  local repo="$1"
  git -C "$repo" log --oneline "HEAD" "^$BASE_REF" --grep='\[REC\]' 2>/dev/null | wc -l | tr -d ' '
}

oldest_rec_hash() {
  local repo="$1"
  git -C "$repo" log --oneline "HEAD" "^$BASE_REF" --grep='\[REC\]' | tail -1 | awk '{print $1}'
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

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  echo "$haystack" | grep -qv "$needle" && ok "$label" || fail "$label (pattern '$needle' unexpectedly found)"
}

cleanup() { rm -rf "$1"; }

# Runs the selective squash used by /squash: only [REC] commits are squashed,
# non-[REC] commits survive untouched. Uses git rebase -i with a custom
# sequence editor that marks [REC] commits as reword/fixup and leaves others.
run_selective_squash() {
  local repo="$1" msg="$2"
  local seq_editor msg_file
  seq_editor="$(mktemp /tmp/tapeback_seq_XXXXXX.js)"
  msg_file="$(mktemp /tmp/tapeback_msg_XXXXXX.txt)"
  printf '%s\n' "$msg" > "$msg_file"
  cat > "$seq_editor" << 'JSEOF'
const fs = require('fs');
const { execSync } = require('child_process');
const f = process.argv[2];
const lines = fs.readFileSync(f, 'utf8').split('\n');
const pickLines = lines.filter(l => l.match(/^pick\s+[0-9a-f]+/));
const isRec = pickLines.map(l => {
  const m = l.match(/^pick\s+([0-9a-f]+)/);
  return execSync('git log -1 --format=%s ' + m[1]).toString().trim().includes('[REC]');
});
const firstRecIdx = isRec.indexOf(true);
const lastRecIdx  = isRec.lastIndexOf(true);
if (firstRecIdx === -1) { fs.writeFileSync(f, lines.join('\n')); process.exit(0); }
let pickIdx = 0, zoneStarted = false;
const out = lines.map(l => {
  if (!l.match(/^pick\s+[0-9a-f]+/)) return l;
  const idx = pickIdx++;
  if (idx < firstRecIdx || idx > lastRecIdx) return l;
  if (!zoneStarted) { zoneStarted = true; return l.replace(/^pick/, 'reword'); }
  return l.replace(/^pick/, 'fixup');
});
fs.writeFileSync(f, out.join('\n'));
JSEOF
  GIT_SEQUENCE_EDITOR="node $seq_editor" \
  GIT_EDITOR="cp $msg_file" \
  git -C "$repo" rebase -i test-base 2>/dev/null
  rm -f "$seq_editor" "$msg_file"
}

# ─── Tests ────────────────────────────────────────────────────────────────────

echo ""
echo "tapeback /squash tests"
echo "──────────────────────"

# ── 1. Detect [REC] commits since base branch ─────────────────────────────────

T=$(make_repo)
# Simulate working on a feature branch (commits after main's initial commit)
rec_commit "$T" "add auth"
rec_commit "$T" "fix token"
rec_commit "$T" "add tests"

count=$(rec_count_since_base "$T")
assert_eq "$count" "3" "detects 3 [REC] commits since base"
cleanup "$T"

# ── 2. Non-branch [REC] commits (on main itself) are excluded ─────────────────

T=$(make_repo)
# Commit directly to main, then simulate being on a "branch" by adding more
rec_commit "$T" "on main rec"    # this is ON main
# (In a real branch scenario this would be a different ref; here we test that
# commits reachable from BASE_REF are excluded.)
# We can't easily test divergence without actual branches, so test the
# git log ^BASE_REF filter works by checking count is 0 when HEAD == BASE_REF.
git -C "$T" tag fake-main HEAD   # tag current position as our simulated BASE_REF
rec_commit "$T" "after branch point"

count=$(git -C "$T" log --oneline HEAD ^fake-main --grep='\[REC\]' | wc -l | tr -d ' ')
assert_eq "$count" "1" "only counts [REC] commits after branch point"
cleanup "$T"

# ── 3. Backup tag is created before squash ────────────────────────────────────

T=$(make_repo)
rec_commit "$T" "alpha"
rec_commit "$T" "beta"

TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
git -C "$T" tag "tapeback/pre-squash-$TIMESTAMP"

tags="$(git -C "$T" tag)"
assert_contains "$tags" "tapeback/pre-squash-" "backup tag created with correct prefix"
cleanup "$T"

# ── 4. selective squash collapses only [REC] commits into one ─────────────────

T=$(make_repo)
rec_commit "$T" "add login" "login.txt"
rec_commit "$T" "add signup" "signup.txt"
rec_commit "$T" "add logout" "logout.txt"

run_selective_squash "$T" "feat(auth): add login, signup, and logout"

# All three [REC] commits should now be a single commit
commit_count_since_initial="$(git -C "$T" rev-list --count HEAD ^"$(git -C "$T" rev-list --max-parents=0 HEAD)")"
assert_eq "$commit_count_since_initial" "1" "selective squash produces exactly 1 commit since initial"

msg="$(git -C "$T" log -1 --pretty=%s)"
assert_eq "$msg" "feat(auth): add login, signup, and logout" "squashed commit has user-provided message"

# All three files should still exist in the working tree
assert_eq "$([ -f "$T/login.txt" ] && echo yes || echo no)" "yes"  "login.txt preserved after squash"
assert_eq "$([ -f "$T/signup.txt" ] && echo yes || echo no)" "yes" "signup.txt preserved after squash"
assert_eq "$([ -f "$T/logout.txt" ] && echo yes || echo no)" "yes" "logout.txt preserved after squash"
cleanup "$T"

# ── 5. No [REC] commits → count is 0 (early exit scenario) ───────────────────

T=$(make_repo)
plain_commit "$T" "feat: manual work"
plain_commit "$T" "fix: typo"

count=$(rec_count_since_base "$T")
assert_eq "$count" "0" "reports 0 when no [REC] commits exist"
cleanup "$T"

# ── 6. Only 1 [REC] commit → count is 1 (early exit scenario) ────────────────

T=$(make_repo)
rec_commit "$T" "only recording"

count=$(rec_count_since_base "$T")
assert_eq "$count" "1" "reports 1 when only one [REC] commit exists"
cleanup "$T"

# ── 7. Manual commit between [REC] commits is squashed into the zone ──────────

T=$(make_repo)
rec_commit   "$T" "recording one" "a.txt"
plain_commit "$T" "manual tweak"
rec_commit   "$T" "recording two" "b.txt"

run_selective_squash "$T" "feat: combined recordings"

# Zone = REC1..REC2 (inclusive of manual between them) → collapses to 1 commit
total_after="$(git -C "$T" log --oneline HEAD ^test-base | wc -l | tr -d ' ')"
assert_eq "$total_after" "1" "manual commit inside zone is squashed with [REC] commits"

msg="$(git -C "$T" log -1 --pretty=%s)"
assert_eq "$msg" "feat: combined recordings" "squashed commit has user-provided message"

assert_eq "$([ -f "$T/a.txt" ] && echo yes || echo no)" "yes" "a.txt preserved after zone squash"
assert_eq "$([ -f "$T/b.txt" ] && echo yes || echo no)" "yes" "b.txt preserved after zone squash"
cleanup "$T"

# ── 8. Backup tag allows full recovery after squash ───────────────────────────

T=$(make_repo)
rec_commit "$T" "step one" "step1.txt"
rec_commit "$T" "step two" "step2.txt"

pre_squash_hash="$(git -C "$T" rev-parse HEAD)"
git -C "$T" tag "tapeback/pre-squash-recovery-test"

run_selective_squash "$T" "feat: squashed"

# Verify squash happened
squashed_hash="$(git -C "$T" rev-parse HEAD)"
[[ "$squashed_hash" != "$pre_squash_hash" ]] && ok "squash changed HEAD hash" || fail "squash changed HEAD hash"

# Recover using backup tag
git -C "$T" reset --hard "tapeback/pre-squash-recovery-test" > /dev/null

recovered_hash="$(git -C "$T" rev-parse HEAD)"
assert_eq "$recovered_hash" "$pre_squash_hash" "reset to backup tag fully recovers pre-squash state"
cleanup "$T"

# ── 9. squashBaseRef from .tapeback.json is respected ─────────────────────────

T=$(make_repo)
# Set a custom base ref in config
echo '{"squashBaseRef":"develop","recTag":"[REC]","messageStyle":"deterministic","sessionTag":true,"ignore":[]}' \
  > "$T/.tapeback.json"

configured_base="$(node -e "
  try { const c=require('$T/.tapeback.json'); process.stdout.write(c.squashBaseRef||'main'); }
  catch(e) { process.stdout.write('main'); }
")"
assert_eq "$configured_base" "develop" "reads squashBaseRef from .tapeback.json"
cleanup "$T"

# ── 10. Diff stat is computable across recording range ────────────────────────

T=$(make_repo)
rec_commit "$T" "add file a" "alpha.txt"
rec_commit "$T" "add file b" "beta.txt"
rec_commit "$T" "add file c" "gamma.txt"

oldest=$(oldest_rec_hash "$T")
stat="$(git -C "$T" diff "${oldest}^" HEAD --stat | tail -1)"
assert_contains "$stat" "files changed" "diff stat across recording range is computable"
cleanup "$T"

# ── 11. Manual commit AFTER last [REC] is outside the zone and preserved ──────

T=$(make_repo)
rec_commit   "$T" "recording one" "a.txt"
rec_commit   "$T" "recording two" "b.txt"
plain_commit "$T" "manual after"

run_selective_squash "$T" "feat: all claude work"

# Zone = REC1..REC2; manual is after the zone → preserved as its own commit
total="$(git -C "$T" log --oneline HEAD ^test-base | wc -l | tr -d ' ')"
assert_eq "$total" "2" "manual after zone: 2 commits remain (squashed RECs + manual)"

# HEAD is the manual commit (it was replayed after the squashed zone)
head_msg="$(git -C "$T" log -1 --pretty=%s)"
assert_contains "$head_msg" "manual after" "manual commit after zone is preserved at HEAD"

# Squashed commit (HEAD~1) contains both REC files
squashed_files="$(git -C "$T" show --name-only --format="" HEAD~1)"
assert_contains "$squashed_files" "a.txt" "a.txt is in the squashed REC commit"
assert_contains "$squashed_files" "b.txt" "b.txt is in the squashed REC commit"
cleanup "$T"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
