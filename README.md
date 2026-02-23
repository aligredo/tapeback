# tapeback 🎞️

> *Like rewinding a tape — tapeback automatically records every Claude Code agent action that changes your codebase, so you can rewind to any moment in your session.*

---

## The problem

Claude Code agents are powerful but imperfect. A single bad message can silently overwrite hours of work across multiple files — with no native undo beyond manual `git` gymnastics.

**tapeback is the rewind button.**

Every time Claude edits a file, tapeback automatically commits the codebase state with a `[REC]` tag. When something goes wrong, one command puts you back where you were.

---

## Install

```bash
# Add to your current project
npx tapeback init

# Or install globally for all projects
npx tapeback init --global
```

That's it. No global install required. tapeback wires itself into Claude Code's hook system and starts recording immediately.

---

## Commands

### `/tapeback` — rewind to any recording

```bash
/tapeback              # undo the last recording
/tapeback 3            # undo the last 3 recordings
/tapeback --to <hash>  # rewind to a specific commit
/tapeback --to "14:30" # rewind to nearest recording before a time
```

tapeback will show you exactly what will change and ask for confirmation before touching anything. If you have uncommitted work, it'll ask whether to stash or abandon it first.

### `/squash` — clean history before a PR

```bash
/squash
```

Squashes every commit from the first `[REC]` to the last `[REC]` — the **squash zone** — into a single conventional commit. Manual commits inside that range are squashed in too; commits before the first `[REC]` or after the last `[REC]` are left untouched.

Shows a summary of everything in the zone, prompts for your final commit message, and creates a backup tag before touching anything.

### `/reel` — interactive git graph

```bash
/reel
```

Renders a self-contained HTML git graph and opens it in your browser. Commits appear as coloured dots (blue = feature, green = base, red = `[REC]`, yellow = diverge point). Hover any dot for full commit details.

---

## How it works

tapeback uses Claude Code's `PostToolUse` hook to fire after every `Write`, `Edit`, or `MultiEdit` tool call.

```
Claude edits file(s)
      ↓
PostToolUse fires
      ↓
Any tracked files changed? ──No──→ exit (silent)
      ↓ Yes
git add -A
      ↓
Generate headline (claude -p with 5s timeout → deterministic fallback)
      ↓
git commit  "chore(tapeback): <headline> [REC]"
      ↓
exit 0  ← always, never blocks Claude
```

Each recording looks like this in `git log`:

```
chore(tapeback): add JWT middleware [REC]

Agent message: "add JWT authentication to the API"
Changed files:
  src/auth/jwt.py  (+42 -3)
  tests/test_auth.py  (+18 -0)

Timestamp: 2026-02-18T14:32:07Z
Session: abc123
```

---

## Configuration

tapeback reads `.tapeback.json` from your project root:

```json
{
  "messageStyle": "ai",
  "aiTimeoutMs": 5000,
  "squashBaseRef": "main",
  "recTag": "[REC]",
  "ignore": ["*.env", "*.log", ".tapeback.json"],
  "sessionTag": true
}
```

| Option | Default | Description |
|---|---|---|
| `messageStyle` | `"ai"` | `"ai"` uses `claude -p` to generate a headline; `"deterministic"` uses filenames |
| `aiTimeoutMs` | `5000` | Hard timeout (ms) before falling back to deterministic headline |
| `squashBaseRef` | `"main"` | Branch that `/squash` measures divergence from |
| `recTag` | `"[REC]"` | Identifier tag in every recording's commit subject |
| `ignore` | `["*.env","*.log"]` | Glob patterns to never stage or commit |
| `sessionTag` | `true` | Include Claude session ID in commit body |

---

## Requirements

- **macOS / Linux** (POSIX shell required — Windows not supported in v1)
- **git** ≥ 2.23
- **Node.js** ≥ 18
- **Claude Code** with hooks support

---

## Privacy & security

tapeback is a pure **git workflow layer** — it stores no credentials, sends no data to external servers, and reads nothing from your codebase beyond what git already tracks.

- **No API keys or tokens** — tapeback never requests, stores, or transmits any credentials
- **No network calls** — the hook is offline; it runs entirely in your local git repo
- **No data collection** — nothing leaves your machine except the optional `claude -p` headline call, which goes through your existing Claude Code session (the same one already running)
- **Open source** — the full hook and command logic is readable in `plugin/hooks/post-tool-use.sh` and `plugin/commands/`

tapeback is a thin wrapper that adds git discipline on top of what Claude Code already does. It maximises Claude's usefulness without adding any new trust surface.

---

## Safety guarantees

- The hook **always exits 0** — it can never block or crash your Claude session
- The hook has a **5-second hard timeout** on AI message generation
- `/squash` **always creates a backup tag** before any git mutation — your session is always recoverable
- `/tapeback` **always previews** what will change and asks for confirmation
- `/reel` is **read-only** — it never modifies git history or files

---

## Repository structure

```
tapeback/
├── .claude-plugin                   # Plugin manifest for Claude Code registry
├── package.json
├── bin/
│   └── tapeback.js                 # CLI entrypoint (npx tapeback init)
├── plugin/
│   ├── hooks/
│   │   └── post-tool-use.sh        # Core auto-record hook
│   ├── commands/
│   │   ├── tapeback.md             # /tapeback slash command
│   │   ├── squash.md               # /squash slash command
│   │   └── reel.md                 # /reel slash command
│   └── settings.json               # Hook wiring for Claude Code
├── src/
│   ├── commit-message.js           # Headline generation module
│   ├── generate-headline.js        # CLI wrapper for the hook
│   ├── git-graph.js                # Git graph data builder
│   └── generate-reel.js            # HTML graph renderer for /reel
├── test/
│   ├── hook.test.sh
│   ├── tapeback.test.sh
│   ├── squash.test.sh
│   ├── reel.test.sh
│   └── commands.test.js
└── .tapeback.json                  # Default config (copied on init)
```

---

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## License

MIT
