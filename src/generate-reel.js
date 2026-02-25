#!/usr/bin/env node
'use strict';

const path = require('path');
const fs   = require('fs');
const os   = require('os');
const { buildGraph } = require(path.join(__dirname, 'git-graph.js'));

// ─── Layout constants ─────────────────────────────────────────────────────────

const ROW_H   = 84;
const PAD_TOP = 72;
const PAD_BOT = 60;
const R       = 10;
const SW      = 960;
const LANE_X  = { 0: 110, '-1': 210, 1: 310 };  // base | shared | feature

const COLORS = {
  feature: '#58a6ff',
  base:    '#3fb950',
  shared:  '#6e7681',
  diverge: '#f0c040',
  rec:     '#ff7b72',
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

function esc(str) {
  return String(str)
    .replace(/&/g,  '&amp;')
    .replace(/</g,  '&lt;')
    .replace(/>/g,  '&gt;')
    .replace(/"/g,  '&quot;');
}

function cy(row)    { return PAD_TOP + row * ROW_H; }
function cx(commit) { return LANE_X[commit.lane] !== undefined ? LANE_X[commit.lane] : LANE_X['-1']; }

function commitColor(c) {
  if (c.isRec) return COLORS.rec;
  return COLORS[c.type] || COLORS.shared;
}

function fmtDate(iso) {
  if (!iso) return '';
  try {
    const d = new Date(iso);
    return d.toLocaleString('en-GB', {
      year: 'numeric', month: 'short', day: 'numeric',
      hour: '2-digit', minute: '2-digit',
    });
  } catch { return iso; }
}

// ─── SVG building blocks ──────────────────────────────────────────────────────

function svgEdge(c1, c2) {
  const x1 = cx(c1), y1 = cy(c1.row);
  const x2 = cx(c2), y2 = cy(c2.row);
  const stroke = '#21262d';
  if (x1 === x2) {
    return '<line x1="' + x1 + '" y1="' + (y1 + R) + '" x2="' + x2 + '" y2="' + (y2 - R) +
           '" stroke="' + stroke + '" stroke-width="2.5"/>';
  }
  const midy = (y1 + y2) / 2;
  return '<path d="M' + x1 + ',' + (y1 + R) +
         ' C' + x1 + ',' + midy + ' ' + x2 + ',' + midy + ' ' + x2 + ',' + (y2 - R) +
         '" fill="none" stroke="' + stroke + '" stroke-width="2.5"/>';
}

function svgDot(c) {
  const x     = cx(c);
  const y     = cy(c.row);
  const color = commitColor(c);
  const short = c.hash.slice(0, 7);
  const parts = [];

  // Glow ring for [REC] commits
  if (c.isRec) {
    parts.push(
      '<circle cx="' + x + '" cy="' + y + '" r="' + (R + 5) + '"' +
      ' fill="none" stroke="' + COLORS.rec + '" stroke-width="1" opacity="0.35" class="rec-ring"/>'
    );
  }

  // Double ring for diverge point
  if (c.type === 'diverge') {
    parts.push(
      '<circle cx="' + x + '" cy="' + y + '" r="' + (R + 4) + '"' +
      ' fill="none" stroke="' + COLORS.diverge + '" stroke-width="1.5" opacity="0.5"/>'
    );
  }

  // Main dot
  parts.push(
    '<circle cx="' + x + '" cy="' + y + '" r="' + R + '"' +
    ' fill="' + color + '" class="dot"' +
    ' data-hash="'    + esc(c.hash)     + '"' +
    ' data-short="'   + esc(short)      + '"' +
    ' data-subject="' + esc(c.subject)  + '"' +
    ' data-author="'  + esc(c.author)   + '"' +
    ' data-date="'    + esc(fmtDate(c.date)) + '"' +
    ' data-type="'    + esc(c.type)     + '"' +
    ' data-rec="'     + (c.isRec ? '1' : '0') + '"' +
    ' data-color="'   + color           + '"' +
    '/>'
  );

  return parts.join('');
}

function svgLabel(c) {
  const x     = cx(c);
  const y     = cy(c.row);
  const short = c.hash.slice(0, 7);
  const subj  = c.subject.length > 52 ? c.subject.slice(0, 49) + '…' : c.subject;
  const lx    = x + R + 14;

  return (
    // Hash in muted monospace
    '<text x="' + lx + '" y="' + (y - 3) + '"' +
    ' fill="#6e7681" font-size="11" font-family="monospace">' +
    esc(short) + '</text>' +
    // Subject in full color
    '<text x="' + lx + '" y="' + (y + 11) + '"' +
    ' fill="#e6edf3" font-size="13" font-family="ui-monospace,\'SF Mono\',monospace">' +
    esc(subj) + '</text>'
  );
}

function svgLaneGuides(svgH) {
  return Object.values(LANE_X).map(function(x) {
    return '<line x1="' + x + '" y1="' + (PAD_TOP - 30) + '" x2="' + x + '" y2="' + (svgH - PAD_BOT + 20) + '"' +
           ' stroke="#21262d" stroke-width="1.5" stroke-dasharray="4 6"/>';
  }).join('');
}

function svgLaneHeaders(featureLabel, baseRef) {
  return (
    '<text x="' + LANE_X[0]  + '" y="28" fill="' + COLORS.base    + '" font-size="12" font-family="monospace" text-anchor="middle" font-weight="600">' + esc(baseRef)      + '</text>' +
    '<text x="' + LANE_X[-1] + '" y="28" fill="' + COLORS.shared  + '" font-size="12" font-family="monospace" text-anchor="middle">' + 'shared'          + '</text>' +
    '<text x="' + LANE_X[1]  + '" y="28" fill="' + COLORS.feature + '" font-size="12" font-family="monospace" text-anchor="middle" font-weight="600">' + esc(featureLabel) + '</text>'
  );
}

// ─── Browser-side script (no template literals — safe to embed) ───────────────

const BROWSER_SCRIPT = [
  '(function() {',
  '  var tip     = document.getElementById("tb-tip");',
  '  var tipHashEl = document.getElementById("tb-tip-hash");',
  '  var tipHash = tipHashEl ? tipHashEl.querySelector("span") : null;',
  '  var tipTag  = document.getElementById("tb-tip-tag");',
  '  var tipSubj = document.getElementById("tb-tip-subj");',
  '  var tipAuth = document.getElementById("tb-tip-auth");',
  '  var tipDate = document.getElementById("tb-tip-date");',
  '  var tipCopy = document.getElementById("tb-tip-copy");',
  '  var dots    = document.querySelectorAll(".dot");',
  '  var activeHash = null;',
  '',
  '  function showTip(d, e) {',
  '    var color = d.dataset.color;',
  '    tipHash.textContent  = d.dataset.short;',
  '    tipHash.style.color  = color;',
  '    tipTag.textContent   = d.dataset.rec === "1" ? "[REC]" : d.dataset.type;',
  '    tipTag.style.background = d.dataset.rec === "1" ? "rgba(255,119,114,0.15)" : "rgba(110,118,129,0.15)";',
  '    tipTag.style.color      = d.dataset.rec === "1" ? "#ff7b72" : "#8b949e";',
  '    tipSubj.textContent  = d.dataset.subject;',
  '    tipAuth.textContent  = d.dataset.author;',
  '    tipDate.textContent  = d.dataset.date;',
  '    tipCopy.textContent  = "click to copy hash";',
  '    tipCopy.style.color  = "#8b949e";',
  '    activeHash = d.dataset.hash;',
  '    tip.style.display = "block";',
  '    moveTip(e);',
  '  }',
  '',
  '  function moveTip(e) {',
  '    var tw = tip.offsetWidth, th = tip.offsetHeight;',
  '    var x  = e.clientX + 18;',
  '    var y  = e.clientY - 12;',
  '    if (x + tw > window.innerWidth  - 12) { x = e.clientX - tw - 18; }',
  '    if (y + th > window.innerHeight - 12) { y = e.clientY - th + 12; }',
  '    tip.style.left = x + "px";',
  '    tip.style.top  = y + "px";',
  '  }',
  '',
  '  for (var i = 0; i < dots.length; i++) {',
  '    (function(d) {',
  '      d.addEventListener("mouseenter", function(e) { showTip(d, e); });',
  '      d.addEventListener("mousemove",  function(e) { moveTip(e); });',
  '      d.addEventListener("mouseleave", function()  { tip.style.display = "none"; activeHash = null; });',
  '      d.addEventListener("click", function() {',
  '        if (!activeHash) { return; }',
  '        navigator.clipboard.writeText(activeHash).then(function() {',
  '          tipCopy.textContent = "copied!";',
  '          tipCopy.style.color = "#3fb950";',
  '          setTimeout(function() {',
  '            tipCopy.textContent = "click to copy hash";',
  '            tipCopy.style.color = "#8b949e";',
  '          }, 1500);',
  '        }).catch(function() {});',
  '      });',
  '    })(dots[i]);',
  '  }',
  '})();',
].join('\n');

// ─── HTML generation ─────────────────────────────────────────────────────────

function generateHTML(graph) {
  const { commits, byHash, featureLabel, baseRef } = graph;
  const svgH    = PAD_TOP + commits.length * ROW_H + PAD_BOT;
  const recCount = commits.filter(function(c) { return c.isRec; }).length;
  const genTime  = new Date().toLocaleString('en-GB', {
    year: 'numeric', month: 'short', day: 'numeric',
    hour: '2-digit', minute: '2-digit',
  });

  let edges = '';
  for (const c of commits) {
    for (const ph of c.parents) {
      const parent = byHash[ph];
      if (parent) edges += svgEdge(c, parent);
    }
  }

  let dots   = '';
  let labels = '';
  for (const c of commits) {
    dots   += svgDot(c);
    labels += svgLabel(c);
  }

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>tapeback reel — ${esc(featureLabel)}</title>
<style>
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

:root {
  --bg:      #0d1117;
  --surface: #161b22;
  --border:  #21262d;
  --text:    #e6edf3;
  --muted:   #8b949e;
}

body {
  background: var(--bg);
  color: var(--text);
  font-family: ui-monospace, 'SF Mono', 'Cascadia Code', monospace;
  height: 100vh;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

/* ── Header ── */
#hd {
  flex-shrink: 0;
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  padding: 0 20px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  height: 52px;
}

#hd-left {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 13px;
  min-width: 0;
}

.hd-logo { font-size: 18px; flex-shrink: 0; }

.hd-branch {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 13px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.hd-sep { color: var(--muted); }

#hd-right {
  display: flex;
  align-items: center;
  gap: 16px;
  flex-shrink: 0;
}

/* ── Legend ── */
.legend {
  display: flex;
  align-items: center;
  gap: 12px;
  font-size: 11px;
  color: var(--muted);
}

.legend-item {
  display: flex;
  align-items: center;
  gap: 5px;
}

.legend-dot {
  width: 9px;
  height: 9px;
  border-radius: 50%;
  flex-shrink: 0;
}

/* ── Stats chips ── */
.stats {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 11px;
  color: var(--muted);
}

.stat-chip {
  padding: 3px 8px;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 12px;
  white-space: nowrap;
}

.stat-chip.rec { border-color: rgba(255,119,114,0.4); color: #ff7b72; }

/* ── SVG scroll area ── */
#canvas {
  flex: 1;
  overflow-y: auto;
  overflow-x: auto;
  scrollbar-width: thin;
  scrollbar-color: #30363d var(--bg);
}

#canvas::-webkit-scrollbar       { width: 8px; height: 8px; }
#canvas::-webkit-scrollbar-track { background: var(--bg); }
#canvas::-webkit-scrollbar-thumb { background: #30363d; border-radius: 4px; }

#reel-svg {
  display: block;
  min-width: 100%;
}

/* ── Dots ── */
.dot {
  cursor: pointer;
  transition: r 0.12s ease, filter 0.12s ease;
}

.dot:hover {
  filter: drop-shadow(0 0 6px currentColor);
}

.rec-ring {
  pointer-events: none;
  animation: rec-pulse 2s ease-in-out infinite;
}

@keyframes rec-pulse {
  0%, 100% { opacity: 0.35; r: 15; }
  50%       { opacity: 0.7;  r: 18; }
}

/* ── Tooltip ── */
#tb-tip {
  display: none;
  position: fixed;
  background: var(--surface);
  border: 1px solid #30363d;
  border-radius: 8px;
  padding: 12px 16px;
  font-size: 12px;
  line-height: 1;
  max-width: 360px;
  min-width: 220px;
  pointer-events: none;
  z-index: 100;
  box-shadow: 0 8px 24px rgba(0,0,0,0.5);
}

#tb-tip-hash {
  font-size: 14px;
  font-weight: 700;
  letter-spacing: 0.04em;
  margin-bottom: 8px;
  display: flex;
  align-items: center;
  gap: 8px;
}

#tb-tip-tag {
  display: inline-block;
  padding: 1px 6px;
  border-radius: 4px;
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.05em;
  text-transform: uppercase;
}

#tb-tip-subj {
  color: #e6edf3;
  font-size: 12px;
  line-height: 1.5;
  margin-bottom: 10px;
  word-break: break-word;
}

.tip-meta {
  color: var(--muted);
  font-size: 11px;
  line-height: 1.7;
  border-top: 1px solid var(--border);
  padding-top: 8px;
  margin-top: 2px;
}

#tb-tip-copy {
  display: block;
  margin-top: 6px;
  font-size: 10px;
  color: var(--muted);
  letter-spacing: 0.03em;
}
</style>
</head>
<body>

<header id="hd">
  <div id="hd-left">
    <span class="hd-logo" aria-hidden="true">🎞️</span>
    <div class="hd-branch">
      <span style="color:${COLORS.feature};font-weight:600">${esc(featureLabel)}</span>
      <span class="hd-sep">←</span>
      <span style="color:${COLORS.base};font-weight:600">${esc(baseRef)}</span>
    </div>
  </div>
  <div id="hd-right">
    <div class="legend">
      <div class="legend-item"><div class="legend-dot" style="background:${COLORS.feature}"></div>feature</div>
      <div class="legend-item"><div class="legend-dot" style="background:${COLORS.base}"></div>base</div>
      <div class="legend-item"><div class="legend-dot" style="background:${COLORS.rec}"></div>[REC]</div>
      <div class="legend-item"><div class="legend-dot" style="background:${COLORS.diverge}"></div>diverge</div>
      <div class="legend-item"><div class="legend-dot" style="background:${COLORS.shared}"></div>shared</div>
    </div>
    <div class="stats">
      <span class="stat-chip">${commits.length} commit${commits.length === 1 ? '' : 's'}</span>
      ${recCount > 0 ? '<span class="stat-chip rec">' + recCount + ' [REC]</span>' : ''}
      <span class="stat-chip" style="color:var(--muted)">${genTime}</span>
    </div>
  </div>
</header>

<div id="tb-tip">
  <div id="tb-tip-hash">
    <span></span><span id="tb-tip-tag"></span>
  </div>
  <div id="tb-tip-subj"></div>
  <div class="tip-meta">
    <div id="tb-tip-auth"></div>
    <div id="tb-tip-date"></div>
    <span id="tb-tip-copy"></span>
  </div>
</div>

<div id="canvas">
  <svg id="reel-svg" width="${SW}" height="${svgH}" viewBox="0 0 ${SW} ${svgH}">
    <rect width="${SW}" height="${svgH}" fill="#0d1117"/>
    ${svgLaneGuides(svgH)}
    ${svgLaneHeaders(featureLabel, baseRef)}
    ${edges}
    ${dots}
    ${labels}
  </svg>
</div>

<script>
${BROWSER_SCRIPT}
</script>
</body>
</html>`;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

const cwd = process.argv[2] || process.cwd();

let graph;
try {
  graph = buildGraph(cwd);
} catch (e) {
  process.stderr.write('[tapeback reel] ' + e.message + '\n');
  process.exit(1);
}

if (!graph.commits.length) {
  process.stderr.write('[tapeback reel] No commits found.\n');
  process.exit(1);
}

const ts      = new Date().toISOString().replace(/[-:]/g, '').replace('T', 'T').slice(0, 15) + 'Z';
const outFile = path.join(os.tmpdir(), 'tapeback-reel-' + ts + '.html');

fs.writeFileSync(outFile, generateHTML(graph));
process.stdout.write(outFile + '\n');
