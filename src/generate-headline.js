#!/usr/bin/env node
'use strict';

// CLI wrapper around commit-message.js — called from the bash hook.
// Usage: node generate-headline.js <style> <timeoutMs> <diffStat> <agentMessage> [file1] [file2] ...
// Prints the headline to stdout. Always exits 0.

const { resolveHeadline } = require('./commit-message.js');

try {
  const [,, style, timeoutMs, diffStat, agentMessage, ...fileNames] = process.argv;

  const headline = resolveHeadline(
    {
      fileNames: fileNames.filter(Boolean),
      diffStat: diffStat || '',
      agentMessage: agentMessage || '',
    },
    style || 'deterministic',
    parseInt(timeoutMs, 10) || 5000
  );

  process.stdout.write(headline);
} catch {
  process.stdout.write('edit files');
}

process.exit(0);
