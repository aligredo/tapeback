# /squash

Squash all tapeback `[REC]` recordings since the branch diverged from the base branch into a single clean conventional commit.

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

### Step 7 — Execute the squash

Find the oldest `[REC]` commit's parent (the commit just before the first recording):
```bash
git log --oneline HEAD ^<BASE_REF> --grep='\[REC\]' | tail -1 | awk '{print $1}'
```
Call this `OLDEST_REC`.

Run an interactive-style squash using `git reset` + `git commit`:
```bash
git reset --soft <OLDEST_REC>^
git commit --no-verify -m "<user-provided message>"
```

This collapses all `[REC]` commits (and any non-REC commits between them on the branch) into a single commit with the user's message.

> Note: If `OLDEST_REC^` does not exist (the oldest recording is the very first commit in the repo), use `--root` instead:
> `git update-ref -d HEAD` then `git commit --no-verify -m "<message>"`

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
- Only squash when there are ≥ 2 `[REC]` commits. For 0 or 1, stop early with a clear message.
- If `git reset --soft` or `git commit` fails, tell the user the exact error and remind them the backup tag exists for recovery.
- Do not push. Squash is a local operation only.
