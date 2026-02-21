# CLAUDE.md — tapeback

This file tells Claude how to work in the `tapeback` repository.

---

## What this repo is

`tapeback` is a Claude Code plugin that automatically records every agent edit
as a `[REC]`-tagged git commit, then provides `/tapeback` and `/squash`
slash commands for rewinding or cleaning up the history.

---

## Repository layout

```
plugin/hooks/post-tool-use.sh   Core bash hook — fires on Write/Edit/MultiEdit
plugin/commands/tapeback.md     /tapeback slash command prompt
plugin/commands/squash.md       /squash slash command prompt
plugin/settings.json            Hook wiring for Claude Code
src/commit-message.js           AI headline generation module
src/generate-headline.js        CLI wrapper called by the hook
bin/tapeback.js                 npx tapeback init CLI
test/hook.test.sh               Hook integration tests (bash, real git sandboxes)
test/tapeback.test.sh           /tapeback integration tests (bash)
test/squash.test.sh             /squash integration tests (bash)
test/commands.test.js           commit-message.js unit tests (node --test)
.tapeback.json                  Default config template (copied on init)
```

---

## Running tests

```bash
# All tests
npm test

# Individual suites
bash test/hook.test.sh
bash test/tapeback.test.sh
bash test/squash.test.sh
node --test test/commands.test.js
```

All tests must pass before committing. There are currently 66 tests.

---

## Key invariants — never break these

1. **The hook must always exit 0.** It must never block a Claude session under
   any circumstance. Every code path in `post-tool-use.sh` ends in `exit 0`.

2. **`[REC]` is the single source of truth.** All filtering, rollback targeting,
   and squash scoping rely on this exact string in the commit subject.
   The tag is configurable via `.tapeback.json` → `recTag`, but the default
   must remain `[REC]`.

3. **Squash always creates a backup tag first.** The `tapeback/pre-squash-<ts>`
   tag must be created before any `git reset --soft` runs.

4. **Rollback never targets non-`[REC]` commits.** Only commits whose subject
   contains the `recTag` string are valid rollback targets.

---

## Commit conventions

This repo uses [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(scope): description       # new feature
fix(scope): description        # bug fix
chore(scope): description      # maintenance, tooling
docs(scope): description       # documentation only
test(scope): description       # test changes only
```

Milestones get their own `feat(vX.Y):` commit.

---

## What NOT to do

- Do not add dependencies to `package.json` without a strong reason. The hook
  is deliberately dependency-free (bash + node stdlib only).
- Do not use `jq` in the hook — it's not universally available. Use `node`.
- Do not use `--no-verify` outside of tapeback's own internal commits
  (the hook uses it intentionally to avoid recursive hook firing).
- Do not push to remote — always let the user do that.
