/* Renderer for the AshesToAutopilot desktop host. Talks to the main process
   through the window.toolkit bridge defined in preload.js. */

let state = null;       // payload from toolkit:init
let running = false;

const $ = (id) => document.getElementById(id);

// --- Rendering --------------------------------------------------------------

function statusBadge(status) {
  switch (status) {
    case 'DONE': return '<span class="badge done">DONE</span>';
    case 'FAIL': return '<span class="badge fail">FAIL</span>';
    case 'SKIP': return '<span class="badge skip">SKIP</span>';
    case 'running': return '<span class="badge running blink">RUN…</span>';
    default: return '<span class="badge not-run">—</span>';
  }
}

function verdictBadge(verdict) {
  switch (verdict) {
    case 'PASS': return '<span class="verdict-pass">[OK]</span>';
    case 'WARN': return '<span class="verdict-warn">[!!]</span>';
    case 'FAIL': return '<span class="verdict-fail">[XX]</span>';
    default: return '';
  }
}

function esc(s) {
  const div = document.createElement('div');
  div.textContent = s == null ? '' : String(s);
  return div.innerHTML;
}

function renderDeviceInfo() {
  const h = state.hostInfo;
  const elev = h.IsElevated
    ? '<b class="elev-ok">Administrator</b>'
    : '<b class="elev-bad">NOT elevated</b>';
  $('device-info').innerHTML =
    `<span>PC: <b>${esc(h.ComputerName)}</b></span>` +
    `<span>Serial: <b>${esc(h.SerialNumber)}</b></span>` +
    `<span>User: <b>${esc(h.CurrentUser)}</b></span>` +
    `<span>Elevation: ${elev}</span>` +
    `<span>Output: <b>${esc(state.outputRoot)}</b></span>`;
}

function renderSteps() {
  const body = $('step-body');
  body.innerHTML = '';
  let lastPhase = '';
  for (const step of state.steps) {
    if (step.phase !== lastPhase) {
      lastPhase = step.phase;
      const tr = document.createElement('tr');
      tr.className = 'phase-row';
      tr.innerHTML = `<td colspan="7">— ${esc(state.phaseLabels[step.phase] || step.phase)}</td>`;
      body.appendChild(tr);
    }
    const tr = document.createElement('tr');
    tr.id = `step-${step.index}`;
    tr.innerHTML =
      `<td><input type="checkbox" class="step-check" data-index="${step.index}"></td>` +
      `<td class="num">${step.index}</td>` +
      `<td>${esc(step.displayName)}</td>` +
      `<td class="status-cell">${statusBadge(step.status)}</td>` +
      `<td class="verdict-cell">${verdictBadge(step.verdict)}</td>` +
      `<td class="result">${esc(step.verdictReason || '')}</td>` +
      `<td><button class="btn-row-run" data-index="${step.index}">Run</button></td>`;
    body.appendChild(tr);
  }
  body.querySelectorAll('.btn-row-run').forEach((btn) => {
    btn.addEventListener('click', () => {
      const idx = Number(btn.dataset.index);
      const step = state.steps.find((s) => s.index === idx);
      startRun([idx], `Single Step — ${step ? step.displayName : idx}`);
    });
  });
}

function updateRow(index, { status, verdict, verdictReason }) {
  const row = $(`step-${index}`);
  if (!row) return;
  row.classList.toggle('running', status === 'running');
  row.querySelector('.status-cell').innerHTML = statusBadge(status);
  row.querySelector('.verdict-cell').innerHTML = verdictBadge(verdict);
  row.querySelector('.result').textContent = verdictReason || '';
  const step = state.steps.find((s) => s.index === index);
  if (step && status !== 'running') {
    step.status = status;
    step.verdict = verdict || null;
    step.verdictReason = verdictReason || null;
  }
  renderCounts();
}

function renderCounts() {
  const done = state.steps.filter((s) => s.status === 'DONE').length;
  const fail = state.steps.filter((s) => s.status === 'FAIL').length;
  const skip = state.steps.filter((s) => s.status === 'SKIP').length;
  const notRun = state.steps.filter((s) => s.status === 'not-run').length;
  $('counts').innerHTML =
    `<span class="c-done">DONE ${done}</span> · ` +
    `<span class="c-fail">FAIL ${fail}</span> · ` +
    `<span class="c-skip">SKIP ${skip}</span> · ` +
    `NOT RUN ${notRun}`;
}

function setBusy(busy) {
  running = busy;
  for (const id of ['btn-quick', 'btn-full', 'btn-selected', 'btn-reset', 'btn-export']) {
    $(id).disabled = busy || !state.isWindows;
  }
  document.querySelectorAll('.btn-row-run').forEach((b) => { b.disabled = busy || !state.isWindows; });
  $('btn-cancel').hidden = !busy;
  $('progress-track').hidden = !busy;
  if (!busy) $('progress-fill').style.width = '0';
}

function setStatus(text) {
  $('status-text').textContent = text;
}

function showReadiness(summary, htmlPath, cancelled) {
  const banner = $('readiness-banner');
  banner.hidden = false;
  let cls, text;
  if (cancelled) {
    cls = 'warnings';
    text = `■ Run cancelled — ${summary.done + summary.fail + summary.skip}/${summary.total} step(s) completed.`;
  } else if (summary.verdictFail === 0 && summary.verdictWarn === 0) {
    cls = 'ready';
    text = '✓ Ready to Wipe — all checks passed.';
  } else if (summary.verdictFail === 0) {
    cls = 'warnings';
    text = `⚠ Ready to Wipe — ${summary.verdictWarn} warning(s) to review.`;
  } else {
    cls = 'not-ready';
    text = `✗ Not Ready — ${summary.verdictFail} blocking issue(s) to resolve.`;
  }
  banner.className = `notice ${cls}`;
  banner.innerHTML = esc(text) + (htmlPath ? ` &nbsp;<a id="open-report">Open HTML report</a>` : '');
  if (htmlPath) {
    $('open-report').addEventListener('click', () => window.toolkit.openPath(htmlPath));
  }
}

// --- Actions ----------------------------------------------------------------

async function startRun(indices, label) {
  if (running || indices.length === 0) return;
  $('readiness-banner').hidden = true;
  setBusy(true);
  setStatus(`Starting ${label}…`);
  try {
    await window.toolkit.run(indices, label);
  } catch (err) {
    setStatus(`Error: ${err.message || err}`);
    setBusy(false);
  }
}

function selectedIndices() {
  return Array.from(document.querySelectorAll('.step-check:checked'))
    .map((c) => Number(c.dataset.index));
}

function wireToolbar() {
  $('btn-quick').addEventListener('click', () => {
    if (confirm('Quick Check runs 12 core scan/check/backup steps. Start?')) {
      startRun(state.quickCheckIndices, 'Quick Check');
    }
  });

  $('btn-full').addEventListener('click', () => {
    if (confirm(`Full Prep runs all ${state.steps.length} steps in sequence.\nThis may take 30+ minutes and some steps will modify settings. Start?`)) {
      startRun(state.steps.map((s) => s.index), 'Full Prep');
    }
  });

  $('btn-selected').addEventListener('click', () => {
    const indices = selectedIndices();
    if (indices.length === 0) {
      setStatus('No steps selected — tick the checkboxes first.');
      return;
    }
    startRun(indices, 'Custom Run');
  });

  $('btn-reset').addEventListener('click', async () => {
    if (!confirm('Reset session? This clears all step statuses and deletes session.json.')) return;
    const res = await window.toolkit.resetSession();
    state.steps = res.steps;
    $('readiness-banner').hidden = true;
    renderSteps();
    renderCounts();
    setStatus('Session reset. All steps marked as not-run.');
  });

  $('btn-export').addEventListener('click', async () => {
    setStatus('Exporting session report…');
    try {
      const res = await window.toolkit.exportReport();
      setStatus(res.htmlPath ? `Exported: ${res.htmlPath}` : `Exported: ${res.jsonPath}`);
      if (res.htmlPath) window.toolkit.openPath(res.htmlPath);
    } catch (err) {
      setStatus(`Export failed: ${err.message || err}`);
    }
  });

  $('btn-output').addEventListener('click', () => window.toolkit.openOutput());

  $('btn-cancel').addEventListener('click', async () => {
    setStatus('Cancelling after current step…');
    await window.toolkit.cancel();
  });

  $('check-all').addEventListener('change', (e) => {
    document.querySelectorAll('.step-check').forEach((c) => { c.checked = e.target.checked; });
  });
}

// --- Run events from main ----------------------------------------------------

window.toolkit.onEvent((channel, data) => {
  if (channel === 'toolkit:step-started') {
    updateRow(data.index, { status: 'running', verdict: null, verdictReason: '' });
    setStatus(`[${data.position}/${data.total}] Running: ${data.displayName}…`);
    $(`step-${data.index}`).scrollIntoView({ block: 'nearest' });
    $('progress-fill').style.width = `${((data.position - 1) / data.total) * 100}%`;
  } else if (channel === 'toolkit:step-finished') {
    updateRow(data.index, { status: data.status, verdict: data.verdict, verdictReason: data.verdictReason || data.summary });
    $('progress-fill').style.width = `${(data.position / data.total) * 100}%`;
  } else if (channel === 'toolkit:run-finished') {
    state.steps = data.steps;
    renderSteps();
    renderCounts();
    setBusy(false);
    setStatus(data.cancelled ? 'Run cancelled.' : 'Run complete.');
    showReadiness(data.summary, data.htmlPath, data.cancelled);
  }
});

// --- Init ---------------------------------------------------------------------

(async function init() {
  wireToolbar();
  state = await window.toolkit.init();
  renderDeviceInfo();
  renderSteps();
  renderCounts();
  $('btn-full').textContent = `▶ Full Prep (${state.steps.length})`;
  $('btn-quick').textContent = `▶ Quick Check (${state.quickCheckIndices.length})`;
  if (!state.isWindows) {
    $('platform-warning').hidden = false;
    setBusy(false);
    setStatus('UI preview mode — run on Windows to execute steps.');
  } else if (!state.hostInfo.IsElevated) {
    $('elevation-warning').hidden = false;
    setStatus('Warning: not elevated.');
  } else if (state.sessionExists) {
    setStatus(`Session resumed from ${state.sessionFile}`);
  } else {
    setStatus('Ready.');
  }
  setBusy(false);
})();
