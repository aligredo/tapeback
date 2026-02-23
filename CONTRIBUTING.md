# Contributing to tapeback

Thanks for your interest in contributing. This document covers everything you need to get started.

---

## Setup

```bash
git clone https://github.com/aligredo/tapeback
cd tapeback
```

No dependencies to install — tapeback uses only Node.js built-ins and bash.

---

## Running tests

```bash
npm test
```

Or run individual suites:

```bash
bash test/hook.test.sh          # Hook integration tests (13)
bash test/tapeback.test.sh      # /tapeback integration tests (19)
bash test/squash.test.sh        # /squash integration tests (22)
bash test/reel.test.sh          # /reel integration tests (10)
node --test test/commands.test.js  # JS unit tests (17)
```

All 81 tests must pass before opening a PR.

---

## Project structure

| Path | What it is |
|---|---|
| `plugin/hooks/post-tool-use.sh` | The core hook — must always exit 0 |
| `plugin/commands/tapeback.md` | `/tapeback` Claude prompt |
| `plugin/commands/squash.md` | `/squash` Claude prompt |
| `plugin/commands/reel.md` | `/reel` Claude prompt |
| `src/git-graph.js` | Git graph data builder |
| `src/generate-reel.js` | HTML graph renderer |
| `src/commit-message.js` | Headline generation module |
| `src/generate-headline.js` | CLI wrapper for the hook |
| `bin/tapeback.js` | `npx tapeback init` CLI |

---

## Invariants

These must never be broken:

1. **The hook always exits 0** — it must never block a Claude session.
2. **`[REC]` is the canonical tag** — all internal logic depends on it.
3. **`/squash` creates a backup tag before any mutation** — the session is always recoverable.
4. **Zero npm dependencies** — the hook runs in any Node.js ≥ 18 environment without `npm install`.

---

## Commit style

This repo uses [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(scope): what you added
fix(scope): what you fixed
test(scope): test changes only
docs(scope): docs only
chore(scope): maintenance
```

---

## Opening a PR

1. Fork the repo and create a feature branch
2. Make your changes
3. Run `npm test` — all tests must pass
4. Open a PR with a clear description of what changed and why

CI will run all tests automatically on every PR.

---

## Reporting bugs

Open an issue at [github.com/aligredo/tapeback/issues](https://github.com/aligredo/tapeback/issues) with:

- Your OS and Node.js version
- The Claude Code version
- Steps to reproduce
- What you expected vs. what happened
