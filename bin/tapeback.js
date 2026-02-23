#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// ─── Helpers ──────────────────────────────────────────────────────────────────

const PLUGIN_DIR  = path.resolve(__dirname, '..', 'plugin');
const SRC_DIR     = path.resolve(__dirname, '..', 'src');
const DEFAULT_CONFIG = path.resolve(__dirname, '..', '.tapeback.json');

function log(msg) {
  process.stdout.write(msg + '\n');
}

function err(msg) {
  process.stderr.write('[tapeback] ' + msg + '\n');
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function copyFile(src, dest) {
  ensureDir(path.dirname(dest));
  fs.copyFileSync(src, dest);
}

/**
 * Deep-merge settings.json hooks into an existing Claude settings file.
 * Existing hooks for the same matcher are not duplicated.
 */
function mergeSettings(existingPath, incomingSettings) {
  let existing = {};
  if (fs.existsSync(existingPath)) {
    try {
      existing = JSON.parse(fs.readFileSync(existingPath, 'utf8'));
    } catch {
      err(`Could not parse existing ${existingPath} — backing it up and replacing.`);
      fs.copyFileSync(existingPath, existingPath + '.bak');
    }
  }

  existing.hooks = existing.hooks || {};

  for (const [event, hookGroups] of Object.entries(incomingSettings.hooks || {})) {
    existing.hooks[event] = existing.hooks[event] || [];

    for (const group of hookGroups) {
      const alreadyWired = existing.hooks[event].some(
        (h) => h.matcher === group.matcher &&
          h.hooks?.some((hh) => hh.command === group.hooks?.[0]?.command)
      );
      if (!alreadyWired) {
        existing.hooks[event].push(group);
      }
    }
  }

  fs.writeFileSync(existingPath, JSON.stringify(existing, null, 2) + '\n');
}

// ─── Commands ─────────────────────────────────────────────────────────────────

function cmdInit(args) {
  const isGlobal = args.includes('--global');
  const targetBase = isGlobal
    ? path.join(process.env.HOME || '~', '.claude')
    : path.join(process.cwd(), '.claude');

  log('');
  log('  🎞  tapeback init');
  log('  ' + '─'.repeat(40));
  log(`  Target: ${targetBase}`);
  log('');

  // 1. Verify git repo (local install only)
  if (!isGlobal) {
    try {
      execSync('git rev-parse --is-inside-work-tree', { stdio: 'ignore' });
    } catch {
      err('Not inside a git repository. tapeback requires git.');
      err('Run `git init` first, then re-run `npx tapeback init`.');
      process.exit(1);
    }
  }

  // 2. Copy hook
  const hookSrc = path.join(PLUGIN_DIR, 'hooks', 'post-tool-use.sh');
  const hookDest = path.join(targetBase, 'hooks', 'post-tool-use.sh');
  copyFile(hookSrc, hookDest);
  fs.chmodSync(hookDest, '755');
  log('  ✓ Hook installed:    ' + path.relative(process.cwd(), hookDest));

  // 3. Copy commands
  const commandsSrc = path.join(PLUGIN_DIR, 'commands');
  if (fs.existsSync(commandsSrc)) {
    for (const file of fs.readdirSync(commandsSrc)) {
      const src = path.join(commandsSrc, file);
      const dest = path.join(targetBase, 'commands', file);
      copyFile(src, dest);
      log('  ✓ Command installed: ' + path.relative(process.cwd(), dest));
    }
  }

  // 4. Copy src/ scripts (needed by /reel and the headline generator)
  if (fs.existsSync(SRC_DIR)) {
    for (const file of fs.readdirSync(SRC_DIR)) {
      const src  = path.join(SRC_DIR, file);
      const dest = path.join(targetBase, 'src', file);
      copyFile(src, dest);
      log('  ✓ Script installed:  ' + path.relative(process.cwd(), dest));
    }
  }

  // 5. Merge settings.json
  const incomingSettings = JSON.parse(
    fs.readFileSync(path.join(PLUGIN_DIR, 'settings.json'), 'utf8')
  );
  const settingsDest = path.join(targetBase, 'settings.json');
  mergeSettings(settingsDest, incomingSettings);
  log('  ✓ Hook wired in:     ' + path.relative(process.cwd(), settingsDest));

  // 6. Copy .tapeback.json (default config) if not already present
  if (!isGlobal) {
    const configDest = path.join(process.cwd(), '.tapeback.json');
    if (!fs.existsSync(configDest)) {
      copyFile(DEFAULT_CONFIG, configDest);
      log('  ✓ Config created:    .tapeback.json');
    } else {
      log('  · Config exists:     .tapeback.json (skipped)');
    }
  }

  log('');
  log('  tapeback is ready. Every Claude Code edit will now be recorded.');
  log('');
  log('  Commands available inside Claude Code:');
  log('    /tapeback        — rewind the last recording');
  log('    /tapeback 3      — rewind the last 3 recordings');
  log('    /squash          — squash all recordings into one clean commit');
  log('    /reel            — open an interactive HTML git graph in your browser');
  log('');
  log('  Configuration: .tapeback.json');
  log('  Docs: https://github.com/aligredo/tapeback');
  log('');
}

function cmdHelp() {
  log('');
  log('  Usage: npx tapeback <command>');
  log('');
  log('  Commands:');
  log('    init             Install tapeback into the current project\'s .claude/ dir');
  log('    init --global    Install tapeback globally via ~/.claude/');
  log('    help             Show this help message');
  log('');
}

// ─── Entry point ──────────────────────────────────────────────────────────────

const [,, command, ...rest] = process.argv;

switch (command) {
  case 'init':
    cmdInit(rest);
    break;
  case 'help':
  case '--help':
  case '-h':
  case undefined:
    cmdHelp();
    break;
  default:
    err(`Unknown command: ${command}`);
    cmdHelp();
    process.exit(1);
}
