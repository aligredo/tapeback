'use strict';

const { execFileSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const MAX_BRANCH_COMMITS = 30;
const MAX_SHARED_COMMITS = 10;

function loadConfig(cwd) {
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(cwd, '.tapeback.json'), 'utf8'));
    return {
      baseRef: cfg.squashBaseRef || 'main',
      recTag:  cfg.recTag        || '[REC]',
    };
  } catch {
    return { baseRef: 'main', recTag: '[REC]' };
  }
}

function git(cwd, ...args) {
  try {
    return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
}

function parseLog(raw, recTag) {
  if (!raw) return [];
  return raw.split('\n').filter(Boolean).map(line => {
    const sep = '\x1f';
    const parts = line.split(sep);
    const [hash, parents, subject, author, date] = parts;
    return {
      hash:    hash    || '',
      parents: parents ? parents.split(' ').filter(Boolean) : [],
      subject: subject || '',
      author:  author  || '',
      date:    date    || '',
      isRec:   (subject || '').includes(recTag),
    };
  });
}

/**
 * Build a graph of commits for the current HEAD vs. baseRef.
 *
 * Returns:
 *   { baseRef, featureLabel, recTag, commits, byHash }
 *
 * commit shape:
 *   { hash, parents, subject, author, date, isRec, lane, type, row }
 *
 * lane:   0 = base-only, 1 = feature, -1 = shared trunk
 * type:   'feature' | 'base' | 'shared' | 'diverge'
 */
function buildGraph(cwd) {
  const { baseRef, recTag } = loadConfig(cwd);
  const sep = '\x1f';
  const fmt = '--format=%H' + sep + '%P' + sep + '%s' + sep + '%ae' + sep + '%ai';

  // Commits on HEAD but not on baseRef (feature lane)
  const featureRaw = git(cwd, 'log', fmt, '-' + MAX_BRANCH_COMMITS, 'HEAD', '^' + baseRef);
  // Commits on baseRef but not on HEAD (base lane)
  const baseRaw    = git(cwd, 'log', fmt, '-' + MAX_BRANCH_COMMITS, baseRef, '^HEAD');
  // Diverge point (merge-base)
  const mergeBase  = git(cwd, 'merge-base', 'HEAD', baseRef);
  // Shared history from the merge-base
  const sharedRaw  = mergeBase
    ? git(cwd, 'log', fmt, '-' + MAX_SHARED_COMMITS, mergeBase)
    : '';

  const featureCommits = parseLog(featureRaw, recTag)
    .map(c => ({ ...c, lane: 1, type: 'feature' }));
  const baseCommits    = parseLog(baseRaw, recTag)
    .map(c => ({ ...c, lane: 0, type: 'base' }));
  const sharedCommits  = parseLog(sharedRaw, recTag)
    .map((c, i) => ({ ...c, lane: -1, type: i === 0 ? 'diverge' : 'shared' }));

  // Interleave feature + base by date (newest first), then shared below
  const upper = [...featureCommits, ...baseCommits].sort(
    (a, b) => new Date(b.date) - new Date(a.date)
  );
  const allCommits = [...upper, ...sharedCommits];
  allCommits.forEach((c, i) => { c.row = i; });

  const byHash = {};
  allCommits.forEach(c => { byHash[c.hash] = c; });

  const featureLabel = git(cwd, 'rev-parse', '--abbrev-ref', 'HEAD') || 'HEAD';

  return { baseRef, featureLabel, recTag, commits: allCommits, byHash };
}

module.exports = { buildGraph };
