# /rollback

Roll back the codebase to a previous tapeback recording.

## Usage

```
/rollback                        # roll back 1 recording (default)
/rollback 3                      # roll back last N recordings
/rollback --to <hash>            # roll back to a specific commit hash
/rollback --to <timestamp>       # roll back to nearest recording at/before a time
                                 # e.g. /rollback --to "14:30"
                                 #      /rollback --to "2026-02-18T14:30"
```

---

## Instructions

When the user runs `/rollback`, follow these steps precisely.

### Step 1 — Parse the argument

- No argument → N = 1
- Integer argument (e.g. `3`) → N = that number
- `--to <hash>` → target mode: specific commit hash
- `--to <timestamp>` → target mode: nearest recording at or before that time

### Step 2 — Find the target commit

Run:
```bash
git log --oneline --grep='\[REC\]'
```

**Count-based (`/rollback` or `/rollback N`):**
Find the Nth `[REC]` commit from the top of the log. That commit's hash is the target.
If fewer than N recordings exist, tell the user how many exist and ask them to confirm or cancel.

**Hash-based (`--to <hash>`):**
Verify the hash exists and has `[REC]` in its subject. If not found or not a tapeback recording, say so and stop.

**Timestamp-based (`--to <timestamp>`):**
Parse the user's time string (assume today's date if only time given, local timezone).
Scan the `[REC]` commit log for the most recent recording whose `Timestamp:` field in the commit body is at or before the target time.
Show the user the matched commit and confirm before proceeding.

### Step 3 — Show what will be rolled back

Display the commits that will be undone (everything from HEAD down to and including the target):
```
Rolling back to:
  <hash>  chore(tapeback): <headline> [REC]
  Timestamp: <from commit body>
  Files affected: <from commit body>
```

### Step 4 — Handle uncommitted changes

Run:
```bash
git status --short
```

If there are uncommitted changes, show them and ask:
```
⚠ You have uncommitted changes:
  - <file> (<status>)

What should I do with them before rolling back?
  [1] Stash them (recoverable later with git stash pop)
  [2] Abandon them (hard reset, irreversible)
  [3] Cancel rollback
```

Wait for the user's choice before continuing.
- Choice 1 → `git stash push -m "tapeback: pre-rollback stash <timestamp>"`
- Choice 2 → proceed (the hard reset in step 6 will discard them)
- Choice 3 → stop, tell the user nothing was changed

### Step 5 — Confirm

Ask:
```
This will reset your working tree to the state at <headline>. Confirm? [y/N]
```

Stop if the user says anything other than `y` or `yes`.

### Step 6 — Execute

```bash
git reset --hard <target-hash>
```

### Step 7 — Report

Show a concise summary:
```
✓ Rolled back to: chore(tapeback): <headline> [REC]
  Timestamp: <timestamp>
  <N> recording(s) undone.

Tip: run /rollback again to go further back, or git stash pop to restore stashed changes.
```

---

## Rules

- Never run `git reset --hard` without first showing the preview (Step 3) and getting confirmation (Step 5).
- Never skip the uncommitted-changes check (Step 4).
- If any git command fails, show the error and stop — do not attempt to recover automatically.
- Only target commits that contain `[REC]` in their subject line. Never reset to a non-tapeback commit.
