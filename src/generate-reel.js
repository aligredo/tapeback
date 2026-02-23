#!/usr/bin/env node
'use strict';

const path = require('path');
const fs   = require('fs');
const os   = require('os');
const { buildGraph } = require(path.join(__dirname, 'git-graph.js'));

// ─── Layout constants ─────────────────────────────────────────────────────────

const ROW_H   = 76;
const PAD_TOP = 60;
const PAD_BOT = 40;
const R       = 9;
const SW      = 680;
const LANE_X  = { 0: 80, 1: 240, '-1': 160 };

const COLORS = {
  feature: '#58a6ff',
  base:    '#3fb950',
  shared:  '#6e7681',
  diverge: '#f0c040',
  rec:     '#ff7b72',
};

// ─── SVG helpers ──────────────────────────────────────────────────────────────

function esc(str) {
  return String(str)
    .replace(/&/g,  '&amp;')
    .replace(/</g,  '&lt;')
    .replace(/>/g,  '&gt;')
    .replace(/"/g,  '&quot;');
}

function cy(row)     { return PAD_TOP + row * ROW_H; }
function cx(commit)  { return LANE_X[commit.lane] !== undefined ? LANE_X[commit.lane] : LANE_X['-1']; }

function commitColor(c) {
  if (c.isRec) return COLORS.rec;
  return COLORS[c.type] || COLORS.shared;
}

function svgEdge(c1, c2) {
  const x1 = cx(c1), y1 = cy(c1.row);
  const x2 = cx(c2), y2 = cy(c2.row);
  const stroke = '#30363d';
  if (x1 === x2) {
    return '<line x1="' + x1 + '" y1="' + y1 + '" x2="' + x2 + '" y2="' + y2 +
           '" stroke="' + stroke + '" stroke-width="2"/>';
  }
  const midy = (y1 + y2) / 2;
  return '<path d="M' + x1 + ',' + y1 +
         ' C' + x1 + ',' + midy + ' ' + x2 + ',' + midy + ' ' + x2 + ',' + y2 +
         '" fill="none" stroke="' + stroke + '" stroke-width="2"/>';
}

// ─── HTML generation ─────────────────────────────────────────────────────────

// Browser-side interaction script.
// Uses only var/function/for — no arrow functions, no template literals,
// so there is no risk of conflict with the outer Node.js template literal.
const BROWSER_SCRIPT = [
  '(function() {',
  '  var tooltip = document.getElementById("tb-tip");',
  '  var dots = document.querySelectorAll(".dot");',
  '  for (var i = 0; i < dots.length; i++) {',
  '    (function(d) {',
  '      d.addEventListener("mouseenter", function() {',
  '        var h = "<strong>" + d.dataset.hash + "</strong>";',
  '        if (d.dataset.rec === "1") {',
  '          h += " <span style=\'color:#ff7b72;font-size:11px\'>[REC]</span>";',
  '        }',
  '        h += "<br><span style=\'color:#e6edf3\'>" + d.dataset.subject + "</span>";',
  '        h += "<br><span style=\'color:#8b949e;font-size:11px\'>" + d.dataset.author + "</span>";',
  '        h += "<br><span style=\'color:#8b949e;font-size:11px\'>" + d.dataset.date + "</span>";',
  '        tooltip.innerHTML = h;',
  '        tooltip.style.display = "block";',
  '      });',
  '      d.addEventListener("mousemove", function(e) {',
  '        tooltip.style.left = (e.clientX + 16) + "px";',
  '        tooltip.style.top  = (e.clientY - 12) + "px";',
  '      });',
  '      d.addEventListener("mouseleave", function() {',
  '        tooltip.style.display = "none";',
  '      });',
  '    })(dots[i]);',
  '  }',
  '})();',
].join('\n');

function generateHTML(graph) {
  const { commits, byHash, featureLabel, baseRef } = graph;
  const svgH = PAD_TOP + commits.length * ROW_H + PAD_BOT;

  // Edges
  let edges = '';
  for (const c of commits) {
    for (const ph of c.parents) {
      const parent = byHash[ph];
      if (parent) edges += svgEdge(c, parent);
    }
  }

  // Dots and labels
  let dots   = '';
  let labels = '';
  for (const c of commits) {
    const x     = cx(c);
    const y     = cy(c.row);
    const color = commitColor(c);
    const short = c.hash.slice(0, 7);
    const subj  = c.subject.length > 48 ? c.subject.slice(0, 45) + '...' : c.subject;

    dots += '<circle cx="' + x + '" cy="' + y + '" r="' + R + '"' +
            ' fill="' + color + '" class="dot"' +
            ' data-hash="'    + esc(short)     + '"' +
            ' data-subject="' + esc(c.subject) + '"' +
            ' data-author="'  + esc(c.author)  + '"' +
            ' data-date="'    + esc(c.date)    + '"' +
            ' data-rec="'     + (c.isRec ? '1' : '0') + '"' +
            '/>';

    labels += '<text x="' + (x + R + 8) + '" y="' + (y + 4) + '"' +
              ' fill="#e6edf3" font-size="12" font-family="monospace">' +
              esc(short) + ' ' + esc(subj) +
              '</text>';
  }

  // Lane headers
  const laneHeaders =
    '<text x="' + LANE_X[0] + '" y="30" fill="' + COLORS.base    + '"' +
    ' font-size="13" font-family="monospace" text-anchor="middle">' + esc(baseRef) + '</text>' +
    '<text x="' + LANE_X[1] + '" y="30" fill="' + COLORS.feature + '"' +
    ' font-size="13" font-family="monospace" text-anchor="middle">' + esc(featureLabel) + '</text>' +
    '<text x="' + LANE_X[-1] + '" y="30" fill="' + COLORS.shared  + '"' +
    ' font-size="13" font-family="monospace" text-anchor="middle">shared</text>';

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>tapeback reel — ${esc(featureLabel)}</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: #0d1117; color: #e6edf3; font-family: monospace; }
header { padding: 14px 24px; font-size: 13px; color: #8b949e;
         border-bottom: 1px solid #21262d; }
header span { font-weight: bold; }
#reel-svg { display: block; }
.dot { cursor: pointer; }
.dot:hover { stroke: #ffffff; stroke-width: 2; }
#tb-tip {
  display: none; position: fixed;
  background: #161b22; border: 1px solid #30363d; border-radius: 6px;
  padding: 10px 14px; font-size: 12px; line-height: 1.7;
  max-width: 380px; pointer-events: none; z-index: 99; color: #8b949e;
}
</style>
</head>
<body>
<header>
  tapeback reel &nbsp;·&nbsp;
  <span style="color:${COLORS.feature}">${esc(featureLabel)}</span>
  &nbsp;←&nbsp;
  <span style="color:${COLORS.base}">${esc(baseRef)}</span>
  &nbsp;·&nbsp; ${commits.length} commit${commits.length === 1 ? '' : 's'}
</header>
<div id="tb-tip"></div>
<svg id="reel-svg" width="${SW}" height="${svgH}" viewBox="0 0 ${SW} ${svgH}">
  <rect width="${SW}" height="${svgH}" fill="#0d1117"/>
  ${laneHeaders}
  ${edges}
  ${dots}
  ${labels}
</svg>
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
