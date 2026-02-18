'use strict';

const { execFileSync } = require('child_process');

const MAX_HEADLINE_LENGTH = 72;
const DEFAULT_TIMEOUT_MS = 5000;

/**
 * Build the prompt sent to claude -p for headline generation.
 *
 * @param {object} ctx
 * @param {string[]} ctx.fileNames     - Changed file names
 * @param {string}   ctx.diffStat      - Output of `git diff --cached --stat` (last line)
 * @param {string}   ctx.agentMessage  - First 200 chars of the agent prompt
 * @returns {string}
 */
function buildPrompt({ fileNames, diffStat, agentMessage }) {
  const files = fileNames.slice(0, 5).join(', ') || 'unknown files';
  const stat = diffStat || '';
  const msg = (agentMessage || '').slice(0, 200);

  return (
    'Generate a single concise conventional commit headline (max 72 chars, no quotes, no period at end) ' +
    'describing these code changes. Use imperative mood. ' +
    'Examples: "add JWT middleware", "fix token expiry validation", "extract auth helper functions". ' +
    `Changed files: ${files}. ` +
    (stat ? `Diff summary: ${stat}. ` : '') +
    (msg ? `Agent instruction: ${msg}. ` : '') +
    'Output ONLY the headline text, nothing else.'
  );
}

/**
 * Generate a conventional commit headline using `claude -p`.
 * Returns null on timeout, error, or invalid output — never throws.
 *
 * @param {object} ctx          - Same shape as buildPrompt ctx
 * @param {number} timeoutMs    - Hard timeout in milliseconds
 * @returns {string|null}
 */
function generateAiHeadline(ctx, timeoutMs = DEFAULT_TIMEOUT_MS) {
  try {
    const prompt = buildPrompt(ctx);
    const output = execFileSync('claude', ['-p', prompt], {
      timeout: timeoutMs,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });

    const headline = output.split('\n')[0].trim().replace(/^["']|["']$/g, '');

    if (!headline || headline.length > MAX_HEADLINE_LENGTH) {
      return null;
    }

    return headline;
  } catch {
    return null;
  }
}

/**
 * Generate a deterministic fallback headline from file names.
 *
 * @param {string[]} fileNames
 * @returns {string}
 */
function deterministicHeadline(fileNames) {
  if (!fileNames || fileNames.length === 0) {
    return 'edit files';
  }

  const names = fileNames
    .slice(0, 3)
    .map((f) => f.split('/').pop())  // basename only
    .join(', ');

  const suffix = fileNames.length > 3 ? ` (+${fileNames.length - 3} more)` : '';
  return `edit ${names}${suffix}`;
}

/**
 * Resolve the final headline using the configured strategy.
 * Always returns a non-empty string.
 *
 * @param {object}  ctx
 * @param {string}  style        - "ai" | "deterministic"
 * @param {number}  timeoutMs
 * @returns {string}
 */
function resolveHeadline(ctx, style = 'deterministic', timeoutMs = DEFAULT_TIMEOUT_MS) {
  if (style === 'ai') {
    const aiResult = generateAiHeadline(ctx, timeoutMs);
    if (aiResult) return aiResult;
  }
  return deterministicHeadline(ctx.fileNames);
}

module.exports = { resolveHeadline, generateAiHeadline, deterministicHeadline, buildPrompt };
