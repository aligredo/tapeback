# /squash

Squash all tapeback `[REC]` recordings into a single clean conventional commit, leaving all other commits untouched.

---

## Instructions

When the user runs `/squash`, follow these steps precisely.

### Step 1 — Load config

Read `.tapeback.json` from the repo root (if it exists):
```bash
node -e "try{const c=require('./.tapeback.json');console.log(c.squashBaseRef||'main')}catch(e){console.log('main')}"
```

Use the result as `BASE_REF`. Default: `main`.

### Step 2 — Find all [REC] commits on this branch

Run:
```bash
git log --oneline HEAD ^<BASE_REF> --grep='\[REC\]'
```

If 0 recordings found:
- Tell the user: "No tapeback recordings found since branching from `<BASE_REF>`. Nothing to squash."
- Stop.

If 1 recording found:
- Tell the user: "Only 1 recording found. You can rename it directly with `git commit --amend` if you like, but there's nothing to squash."
- Stop.

### Step 3 — Summarize the recordings

For each `[REC]` commit found (newest first), extract:
- The headline (commit subject, minus the `chore(tapeback):` prefix and `[REC]` suffix)
- The files changed (from `git show --stat <hash>`)

Aggregate across all commits:
- Total unique files changed
- Total `+additions` and `-deletions` (from `git diff <oldest-rec-hash>^ HEAD --stat | tail -1`)

Display:
```
Found <N> [REC] recordings since branching from <BASE_REF>.

─────────────────────────────────────────────
Summary of all recorded changes:
  - <headline 1>    (<files changed>)
  - <headline 2>    (<files changed>)
  - ...

Files changed: <X> files  |  +<additions> additions  -<deletions> deletions
─────────────────────────────────────────────
```

### Step 4 — Safety: create a backup tag

Before touching anything, create a backup tag:
```bash
git tag tapeback/pre-squash-<timestamp>
```

Where `<timestamp>` is the current UTC time in format `YYYYMMDDTHHMMSSZ` (e.g. `20260218T143207Z`).

Tell the user: "Created backup tag `tapeback/pre-squash-<timestamp>`. You can always recover with `git reset --hard tapeback/pre-squash-<timestamp>`."

### Step 5 — Prompt for the final commit message

Ask the user:
```
Write your final commit message (conventional commits format):
>
```

Wait for the user's input. The message should follow conventional commits format, e.g.:
- `feat(auth): add JWT middleware and token validation`
- `fix(api): resolve race condition in request handler`

If the user provides an empty message, ask again.

### Step 6 — Check for uncommitted changes

Run:
```bash
git status --short
```

If uncommitted changes exist, warn the user:
```
⚠ You have uncommitted changes that are not part of any recording.
  These will NOT be included in the squash.
  Stash or commit them first if you want them included.

Proceed anyway? [y/N]
```

Stop if the user says anything other than `y` or `yes`.

### Step 7 — Execute the selective squash

Only `[REC]` commits are squashed. All non-`[REC]` commits survive untouched in the history.

**a. Write the final commit message to a temp file:**
```bash
printf '%s\n' "<user-provided message>" > /tmp/tapeback_squash_msg.txt
```

**b. Write the sequence editor script to a temp file:**
```bash
cat > /tmp/tapeback_seq_editor.js << 'EOF'
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const f = process.argv[2];
const repoRoot = execSync('git rev-parse --show-toplevel').toString().trim();
let recTag = '[REC]';
try { recTag = JSON.parse(fs.readFileSync(path.join(repoRoot, '.tapeback.json'), 'utf8')).recTag || '[REC]'; } catch {}
const lines = fs.readFileSync(f, 'utf8').split('\n');
const recLines = [], nonRecLines = [], otherLines = [];
for (const l of lines) {
  const m = l.match(/^pick\s+([0-9a-f]+)/);
  if (!m) { otherLines.push(l); continue; }
  const subject = execSync('git log -1 --format=%s ' + m[1]).toString().trim();
  (subject.includes(recTag) ? recLines : nonRecLines).push(l);
}
const out = [
  ...recLines.map((l, i) => l.replace(/^pick/, i === 0 ? 'reword' : 'fixup')),
  ...nonRecLines,
  ...otherLines,
];
fs.writeFileSync(f, out.join('\n'));
EOF
```

**c. Run the interactive rebase:**
```bash
GIT_SEQUENCE_EDITOR="node /tmp/tapeback_seq_editor.js" \
GIT_EDITOR="cp /tmp/tapeback_squash_msg.txt" \
git rebase -i <BASE_REF>
```

The sequence editor groups all `[REC]` commits together at the top of the rebase todo (oldest first), marking the first as `reword` (git applies the user's message) and the rest as `fixup` (squashed into it, messages discarded). All non-`[REC]` commits follow as `pick` and are replayed unchanged on top of the squashed result.

This handles interleaved commits correctly: even if the user made manual commits between recordings, all `[REC]` changes land in a single commit and manual commits survive untouched.

**d. Clean up:**
```bash
rm -f /tmp/tapeback_squash_msg.txt /tmp/tapeback_seq_editor.js
```

> If `git rebase` reports a conflict, stop immediately. Tell the user to resolve the conflict manually and run `git rebase --continue`, then remind them the backup tag is available for a full reset if needed.

### Step 8 — Report

```
✓ Squashed <N> recordings into one commit.

  <user-provided message>

  Files changed: <X> files  |  +<additions> additions  -<deletions> deletions

Recovery: git reset --hard tapeback/pre-squash-<timestamp>
```

---

## Rules

- **Always** create the backup tag (Step 4) before any git mutation.
- Never squash commits from other branches. Only squash commits reachable from `HEAD` but not from `BASE_REF`.
- Never squash non-`[REC]` commits. Only commits whose subject contains the `recTag` string are squash targets.
- Only squash when there are ≥ 2 `[REC]` commits. For 0 or 1, stop early with a clear message.
- If `git rebase` fails, tell the user the exact error and remind them the backup tag exists for recovery.
- Do not push. Squash is a local operation only.
