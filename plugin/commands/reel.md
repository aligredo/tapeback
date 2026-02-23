# /reel

Render an interactive HTML git graph for the current branch — commits as coloured dots, branches as lines, hover for full commit details.

---

## Instructions

When the user runs `/reel`, follow these steps precisely.

### Step 1 — Generate the graph

Run:
```bash
node .claude/src/generate-reel.js
```

This prints a single line: the path to a self-contained HTML file in `/tmp/`.

If the command fails (e.g. `generate-reel.js` not found), tell the user:
```
⚠ generate-reel.js not found. Re-run `npx tapeback init` to reinstall the plugin.
```
Then stop.

### Step 2 — Open in browser

**macOS:**
```bash
open <path>
```

**Linux:**
```bash
xdg-open <path>
```

Tell the user what you did and remind them they can also open the file manually.

### Step 3 — Report

```
✓ Opened tapeback reel: <path>

  Hover any dot to see commit details.
  [REC] commits are highlighted in red.
  The diverge point is shown in yellow.
```

---

## Rules

- Never modify or delete the generated HTML file.
- If `git rebase` or other operations are in progress, note that the graph reflects the current HEAD state.
- Do not push or commit anything. `/reel` is read-only.
