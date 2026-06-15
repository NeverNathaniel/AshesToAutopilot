// Electron main process — desktop host for the AshesToAutopilot pre-wipe toolkit.
//
// The PowerShell scripts in Scripts/ remain the execution engine. This process
// replaces the console orchestrator (Start-PreWipeToolkit.ps1) UI: it runs each
// step through Scripts/Common/Invoke-ToolkitStep.ps1, which reuses the
// toolkit's own verdict/summary logic, and persists session state to the same
// C:\PreWipeOutput\session.json the console toolkit uses — the two stay
// interchangeable on a device.

const { app, BrowserWindow, ipcMain, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');
const { STEPS, QUICK_CHECK_INDICES, PHASE_LABELS } = require('./steps');

const IS_WIN = process.platform === 'win32';

// In the packaged portable exe, Scripts/ is shipped under resources/toolkit
// (outside the asar) so powershell.exe can execute the files from disk.
const TOOLKIT_ROOT = app.isPackaged
  ? path.join(process.resourcesPath, 'toolkit')
  : path.join(__dirname, '..');

// Same output root the PowerShell toolkit uses; non-Windows fallback exists
// only so the UI can be developed off-device.
const OUTPUT_ROOT = IS_WIN ? 'C:\\PreWipeOutput' : path.join(os.homedir(), 'PreWipeOutput');
const SESSION_FILE = path.join(OUTPUT_ROOT, 'session.json');

const RESULT_BEGIN = '===ATA_RESULT_BEGIN===';
const RESULT_END = '===ATA_RESULT_END===';

let mainWindow = null;
let hostInfo = null;
let activeRun = null; // { cancelled: bool, child: ChildProcess|null }

// --- PowerShell helpers ---------------------------------------------------

function toolkitPath(relPath) {
  return path.join(TOOLKIT_ROOT, ...relPath.split(/[\\/]/));
}

function runPowerShellFile(scriptAbsPath, args, onSpawn) {
  return new Promise((resolve) => {
    const child = spawn(
      'powershell.exe',
      ['-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', scriptAbsPath, ...args],
      { windowsHide: true }
    );
    let stdout = '';
    let stderr = '';
    // The shims emit UTF-8; decode explicitly to match.
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('error', (err) => resolve({ code: -1, stdout, stderr: String(err) }));
    child.on('close', (code) => resolve({ code, stdout, stderr }));
    if (onSpawn) onSpawn(child);
  });
}

// Extracts the JSON envelope a host shim prints between sentinel lines,
// ignoring any console noise the toolkit scripts emit around it.
function extractEnvelope(stdout) {
  const begin = stdout.lastIndexOf(RESULT_BEGIN);
  const end = stdout.lastIndexOf(RESULT_END);
  if (begin === -1 || end === -1 || end < begin) return null;
  const raw = stdout.slice(begin + RESULT_BEGIN.length, end).trim();
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function killProcessTree(child) {
  if (!child || child.killed) return;
  if (IS_WIN) {
    // The step shim spawns its own children (DCU, installers); kill the tree.
    spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true });
  } else {
    child.kill('SIGKILL');
  }
}

// --- Host info ------------------------------------------------------------

async function getHostInfo() {
  if (hostInfo) return hostInfo;
  const fallback = {
    ComputerName: os.hostname(),
    SerialNumber: 'Unknown',
    CurrentUser: os.userInfo().username,
    IsElevated: false,
    PrimaryProfile: null
  };
  if (!IS_WIN) {
    hostInfo = fallback;
    return hostInfo;
  }
  const res = await runPowerShellFile(toolkitPath('Scripts\\Common\\Get-ToolkitHostInfo.ps1'), []);
  hostInfo = extractEnvelope(res.stdout) || fallback;
  return hostInfo;
}

// --- Session persistence (same schema as Save-Session in the orchestrator) -

function newSession(info) {
  const steps = {};
  for (const s of STEPS) {
    steps[String(s.index)] = { Status: 'not-run', Timestamp: null, ExitCode: null, Verdict: null, VerdictReason: null };
  }
  return {
    StartTime: new Date().toISOString(),
    ComputerName: info.ComputerName,
    SerialNumber: info.SerialNumber,
    CurrentUser: info.CurrentUser,
    Steps: steps
  };
}

function loadSession(info) {
  try {
    const raw = JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8'));
    if (raw && raw.Steps) {
      // Ensure every known step has an entry even if session.json predates it.
      const session = newSession(info);
      session.StartTime = raw.StartTime || session.StartTime;
      session.ComputerName = raw.ComputerName || session.ComputerName;
      session.SerialNumber = raw.SerialNumber || session.SerialNumber;
      session.CurrentUser = raw.CurrentUser || session.CurrentUser;
      for (const key of Object.keys(raw.Steps)) {
        if (raw.Steps[key] && raw.Steps[key].Status) session.Steps[key] = raw.Steps[key];
      }
      return session;
    }
  } catch {
    // Missing or corrupt session — start fresh, matching Import-Session.
  }
  return newSession(info);
}

function saveSession(session) {
  fs.mkdirSync(OUTPUT_ROOT, { recursive: true });
  fs.writeFileSync(SESSION_FILE, JSON.stringify(session, null, 2), 'utf8');
}

function stepsWithSession(session) {
  return STEPS.map((s) => {
    const sd = session.Steps[String(s.index)] || {};
    return {
      ...s,
      status: sd.Status || 'not-run',
      verdict: sd.Verdict || null,
      verdictReason: sd.VerdictReason || null,
      timestamp: sd.Timestamp || null
    };
  });
}

// --- Step execution -------------------------------------------------------

async function runSingleStep(step, info) {
  const shim = toolkitPath('Scripts\\Common\\Invoke-ToolkitStep.ps1');
  const args = ['-ToolkitRoot', TOOLKIT_ROOT, '-ScriptPath', step.scriptPath];
  if (info.PrimaryProfile) args.push('-PrimaryProfile', info.PrimaryProfile);
  const res = await runPowerShellFile(shim, args, (child) => {
    if (activeRun) activeRun.child = child;
  });
  if (activeRun) activeRun.child = null;
  if (activeRun && activeRun.cancelled) return null;
  const envelope = extractEnvelope(res.stdout);
  if (envelope) return envelope;
  return {
    Status: 'FAIL',
    ExitCode: res.code,
    Summary: (res.stderr || res.stdout || 'Host shim produced no result').trim().slice(0, 300),
    Verdict: 'FAIL',
    VerdictReason: 'Step host did not return a result',
    ElapsedSeconds: null,
    Parsed: null
  };
}

async function generateHtmlReport(results, runLabel, session, info) {
  if (!IS_WIN) return null;
  const payload = {
    RunLabel: runLabel,
    StartTime: session.StartTime,
    ComputerName: session.ComputerName,
    SerialNumber: session.SerialNumber,
    CurrentUser: session.CurrentUser,
    PrimaryProfile: info.PrimaryProfile,
    Steps: STEPS.map((s) => ({
      Index: s.index,
      Phase: s.phase,
      DisplayName: s.displayName,
      ScriptPath: s.scriptPath,
      Status: (session.Steps[String(s.index)] || {}).Status || 'not-run'
    })),
    SessionSteps: session.Steps,
    Results: results
  };
  const payloadFile = path.join(os.tmpdir(), `ata-report-${Date.now()}.json`);
  fs.writeFileSync(payloadFile, JSON.stringify(payload), 'utf8');
  try {
    const res = await runPowerShellFile(
      toolkitPath('Scripts\\Common\\Export-ToolkitReport.ps1'),
      ['-ToolkitRoot', TOOLKIT_ROOT, '-InputFile', payloadFile]
    );
    const envelope = extractEnvelope(res.stdout);
    return envelope ? envelope.HtmlPath : null;
  } finally {
    fs.rmSync(payloadFile, { force: true });
  }
}

// --- IPC ------------------------------------------------------------------

ipcMain.handle('toolkit:init', async () => {
  const info = await getHostInfo();
  const session = loadSession(info);
  return {
    isWindows: IS_WIN,
    isPackaged: app.isPackaged,
    hostInfo: info,
    outputRoot: OUTPUT_ROOT,
    sessionFile: SESSION_FILE,
    sessionExists: fs.existsSync(SESSION_FILE),
    phaseLabels: PHASE_LABELS,
    quickCheckIndices: QUICK_CHECK_INDICES,
    steps: stepsWithSession(session)
  };
});

ipcMain.handle('toolkit:run', async (event, { indices, label }) => {
  if (activeRun) throw new Error('A run is already in progress');
  if (!IS_WIN) throw new Error('Steps can only run on Windows');

  const info = await getHostInfo();
  const stepsToRun = indices
    .map((i) => STEPS.find((s) => s.index === i))
    .filter(Boolean);

  activeRun = { cancelled: false, child: null };
  const session = loadSession(info);
  const results = [];
  const win = BrowserWindow.fromWebContents(event.sender);
  const send = (channel, data) => {
    if (win && !win.isDestroyed()) win.webContents.send(channel, data);
  };

  try {
    for (let i = 0; i < stepsToRun.length; i++) {
      if (activeRun.cancelled) break;
      const step = stepsToRun[i];
      send('toolkit:step-started', { index: step.index, position: i + 1, total: stepsToRun.length, displayName: step.displayName });

      const envelope = await runSingleStep(step, info);
      if (!envelope) break; // cancelled mid-step

      session.Steps[String(step.index)] = {
        Status: envelope.Status,
        Timestamp: new Date().toISOString(),
        ExitCode: envelope.ExitCode,
        Verdict: envelope.Verdict,
        VerdictReason: envelope.VerdictReason
      };
      saveSession(session);

      results.push({
        Index: step.index,
        Phase: step.phase,
        DisplayName: step.displayName,
        ScriptPath: step.scriptPath,
        Status: envelope.Status,
        Summary: envelope.Summary,
        ParsedData: envelope.Parsed,
        Elapsed: null,
        Verdict: envelope.Verdict,
        VerdictReason: envelope.VerdictReason
      });

      send('toolkit:step-finished', {
        index: step.index,
        position: i + 1,
        total: stepsToRun.length,
        status: envelope.Status,
        verdict: envelope.Verdict,
        verdictReason: envelope.VerdictReason,
        summary: envelope.Summary,
        elapsedSeconds: envelope.ElapsedSeconds
      });
    }

    let htmlPath = null;
    if (results.length > 0) {
      try {
        htmlPath = await generateHtmlReport(results, label || 'Custom Run', session, info);
      } catch {
        htmlPath = null;
      }
    }

    const summary = {
      total: stepsToRun.length,
      done: results.filter((r) => r.Status === 'DONE').length,
      fail: results.filter((r) => r.Status === 'FAIL').length,
      skip: results.filter((r) => r.Status === 'SKIP').length,
      verdictFail: results.filter((r) => r.Verdict === 'FAIL').length,
      verdictWarn: results.filter((r) => r.Verdict === 'WARN').length
    };
    const cancelled = activeRun.cancelled;
    send('toolkit:run-finished', { cancelled, htmlPath, summary, steps: stepsWithSession(session) });
    return { ok: true, cancelled };
  } finally {
    activeRun = null;
  }
});

ipcMain.handle('toolkit:cancel', () => {
  if (!activeRun) return false;
  activeRun.cancelled = true;
  killProcessTree(activeRun.child);
  return true;
});

ipcMain.handle('toolkit:reset-session', async () => {
  const info = await getHostInfo();
  fs.rmSync(SESSION_FILE, { force: true });
  const session = newSession(info);
  return { steps: stepsWithSession(session) };
});

ipcMain.handle('toolkit:export-report', async () => {
  const info = await getHostInfo();
  const session = loadSession(info);

  // Mirror Export-SessionReport: HTML from session state plus a JSON export.
  const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15).replace(/(\d{8})(\d{6})/, '$1-$2');
  const jsonPath = path.join(OUTPUT_ROOT, `PreWipeReport_${session.ComputerName}_${stamp}.json`);
  fs.mkdirSync(OUTPUT_ROOT, { recursive: true });
  fs.writeFileSync(jsonPath, JSON.stringify(session, null, 2), 'utf8');

  const results = STEPS.map((s) => {
    const sd = session.Steps[String(s.index)] || {};
    return {
      Index: s.index,
      Phase: s.phase,
      DisplayName: s.displayName,
      ScriptPath: s.scriptPath,
      Status: sd.Status || 'not-run',
      Summary: sd.VerdictReason || '',
      ParsedData: null,
      Elapsed: null,
      Verdict: sd.Verdict || null,
      VerdictReason: sd.VerdictReason || null
    };
  }).filter((r) => r.Status !== 'not-run');

  let htmlPath = null;
  if (results.length > 0) {
    htmlPath = await generateHtmlReport(results, 'Session Export', session, info);
  }
  return { jsonPath, htmlPath };
});

ipcMain.handle('toolkit:open-output', () => {
  fs.mkdirSync(OUTPUT_ROOT, { recursive: true });
  return shell.openPath(OUTPUT_ROOT);
});

ipcMain.handle('toolkit:open-path', (event, p) => {
  if (typeof p !== 'string' || !p) return 'invalid path';
  return shell.openPath(p);
});

// --- Window ---------------------------------------------------------------

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1180,
    height: 840,
    minWidth: 900,
    minHeight: 600,
    backgroundColor: '#0b0f14',
    autoHideMenuBar: true,
    title: 'AshesToAutopilot — Pre-Wipe Toolkit',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  // Dev/CI smoke-test hook: capture the window and exit.
  if (process.env.ATA_SCREENSHOT) {
    mainWindow.webContents.once('did-finish-load', () => {
      setTimeout(async () => {
        const image = await mainWindow.webContents.capturePage();
        fs.writeFileSync(process.env.ATA_SCREENSHOT, image.toPNG());
        app.quit();
      }, 1500);
    });
  }
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (activeRun) {
    activeRun.cancelled = true;
    killProcessTree(activeRun.child);
  }
  app.quit();
});
