// #749 spike: the menu-bar popup as an Electron tray panel. Not wired into
// the desktop app; run it straight off the Electron binary:
//
//   apps/desktop/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron \
//     apps/desktop/spike/popup/main.cjs [--auto]
//
// `--auto` shows the panel under the tray item without a click, runs the
// measurement conditions (see `measure`), prints one JSON report and quits.
// Without it the tray item toggles the panel and the process stays up.
//
// What it prototypes: one account row with a countdown and two continuous
// effects (a compositor-only CSS shimmer, a canvas ember loop on rAF), in a
// frameless always-on-top NSPanel with system vibrancy, fed from an inline
// fixture shaped like `InfinitusSnapshot`. The data path is stubbed on
// purpose: it does not move idle CPU, which is the gate; it moves RSS, so
// the RSS here is a floor.
"use strict";

const { app, BrowserWindow, Tray, nativeImage, screen, ipcMain } = require("electron");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

// Nothing of this lands in the real app's Application Support.
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "infinitus-popup-spike-"));
app.setPath("userData", scratch);

const AUTO = process.argv.includes("--auto");
/** `--shot`: show the panel, capture it, quit; no measurement. */
const SHOT = process.argv.includes("--shot");
const WIDTH = 360;
const HEIGHT = 168;
const SAMPLE_MS = 15_000;

/** Shaped as `InfinitusSnapshot` (packages/contracts/src/infinitus.ts):
    `usage` is opaque there, so the countdown reads a `resetsAt` this
    fixture puts in it. */
const snapshot = {
  available: true,
  fleets: [
    {
      key: "swapd/claude",
      engineID: "swapd",
      provider: "claude",
      capabilities: ["switch", "rotate"],
      activeNumber: 1,
      headroom: { state: "abundant", window: "5h", pct: 31 },
      accounts: [
        {
          number: 1,
          email: "one@example.com",
          alias: "Work",
          active: true,
          isOrganization: false,
          usageStatus: "ok",
          usage: {
            fiveHour: { pct: 31, resetsAt: new Date(Date.now() + 2 * 3_600_000 + 47 * 60_000).toISOString() },
            sevenDay: { pct: 58 },
          },
        },
      ],
    },
  ],
  sessions: [],
  commands: [],
};

let tray = null;
let panel = null;

const panelOptions = () => ({
  width: WIDTH,
  height: HEIGHT,
  show: false,
  frame: false,
  resizable: false,
  movable: false,
  minimizable: false,
  maximizable: false,
  fullscreenable: false,
  skipTaskbar: true,
  hasShadow: true,
  alwaysOnTop: true,
  hiddenInMissionControl: true,
  // NSPanel: the non-activating analog of the native popup.
  type: "panel",
  transparent: true,
  backgroundColor: "#00000000",
  // System material; glass runs in all states (hard-won fact on the native
  // side: never a focus swap around it).
  vibrancy: "popover",
  visualEffectState: "active",
  roundedCorners: true,
  webPreferences: {
    preload: path.join(__dirname, "preload.cjs"),
    contextIsolation: true,
    nodeIntegration: false,
    sandbox: true,
    // Chromium throttles timers and rAF of a hidden window on its own; the
    // page also stops its rAF loop on the explicit hide signal below.
    backgroundThrottling: true,
  },
});

/** The item's bounds from its last click event: `Tray.getBounds()` answers
    `{x: 0, y: <screen height>}` until the item has been clicked once
    (observed on 44.1.0 with two displays), so `--auto` falls back to the
    primary display's top-right corner. */
let lastTrayBounds = null;
const trayBounds = () => {
  if (lastTrayBounds !== null) return lastTrayBounds;
  const reported = tray.getBounds();
  const primary = screen.getPrimaryDisplay();
  const degenerate = reported.width === 0 || reported.y >= primary.bounds.height - 1;
  if (!degenerate) return reported;
  return { x: primary.bounds.x + primary.bounds.width - 120, y: primary.bounds.y, width: 33, height: 22 };
};

const anchorUnderTray = () => {
  const bounds = trayBounds();
  const display = screen.getDisplayNearestPoint({ x: bounds.x, y: bounds.y });
  const x = Math.round(
    Math.min(
      Math.max(bounds.x + bounds.width / 2 - WIDTH / 2, display.workArea.x),
      display.workArea.x + display.workArea.width - WIDTH,
    ),
  );
  const y = Math.round(bounds.y + bounds.height + 4);
  panel.setPosition(x, y, false);
};

const showPanel = () => {
  anchorUnderTray();
  panel.showInactive();
  panel.webContents.send("spike:visible", true);
};

const hidePanel = () => {
  panel.webContents.send("spike:visible", false);
  panel.hide();
};

const createPanel = () => {
  panel = new BrowserWindow(panelOptions());
  panel.setAlwaysOnTop(true, "pop-up-menu");
  panel.on("blur", () => {
    if (!AUTO && !SHOT && panel.isVisible()) hidePanel();
  });
  return panel.loadFile(path.join(__dirname, "popup.html"));
};

const createTray = () => {
  // An empty image has zero width and cannot be clicked; the title gives it
  // one, the way the native item draws text.
  tray = new Tray(nativeImage.createEmpty());
  tray.setTitle("◐ 31%");
  tray.setToolTip("Infinitus popup spike (#749)");
  tray.on("click", (_event, bounds) => {
    lastTrayBounds = bounds;
    if (panel.isVisible()) hidePanel();
    else showPanel();
  });
};

ipcMain.handle("spike:snapshot", () => snapshot);

// --- measurement -----------------------------------------------------------

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// WindowServer composites every window on screen; its cost is outside both
// this report's process numbers and native's `perf`, so it is sampled apart.
const windowServerPid = (() => {
  try {
    return Number(childProcess.execFileSync("pgrep", ["-x", "WindowServer"], { encoding: "utf8" }).trim().split("\n")[0]);
  } catch {
    return null;
  }
})();

const psSample = () => {
  const pids = app.getAppMetrics().map((m) => m.pid);
  if (windowServerPid !== null) pids.push(windowServerPid);
  const out = childProcess
    .execFileSync("ps", ["-o", "pid=,cputime=,rss=", "-p", pids.join(",")], { encoding: "utf8" })
    .trim()
    .split("\n");
  const rows = out.map((line) => {
    const [pid, cputime, rss] = line.trim().split(/\s+/);
    // cputime is [[dd-]hh:]mm:ss.cc
    const parts = cputime.split(":").map(Number);
    const seconds = parts.reduce((total, part) => total * 60 + part, 0);
    return { pid: Number(pid), cpuSeconds: seconds, rssKb: Number(rss) };
  });
  const own = rows.filter((row) => row.pid !== windowServerPid);
  const windowServer = rows.find((row) => row.pid === windowServerPid);
  return {
    cpuSeconds: own.reduce((sum, row) => sum + row.cpuSeconds, 0),
    rssMb: Math.round(own.reduce((sum, row) => sum + row.rssKb, 0) / 1024),
    windowServerCpuSeconds: windowServer ? windowServer.cpuSeconds : 0,
    at: Date.now(),
  };
};

/** One interval: Electron's own per-process CPU % over the interval (call
    `getAppMetrics` once before to start the clock) and the `ps` cputime
    delta as a second opinion. */
const sampleInterval = async (ms) => {
  const before = psSample();
  app.getAppMetrics();
  await sleep(ms);
  const metrics = app.getAppMetrics();
  const after = psSample();
  const byType = {};
  for (const m of metrics) {
    const key = m.type + (m.name ? `:${m.name}` : "");
    byType[key] = {
      cpuPct: Number(m.cpu.percentCPUUsage.toFixed(2)),
      workingSetMb: Math.round(m.memory.workingSetSize / 1024),
    };
  }
  const elapsed = (after.at - before.at) / 1000;
  return {
    electronCpuPct: Number(metrics.reduce((sum, m) => sum + m.cpu.percentCPUUsage, 0).toFixed(2)),
    psCpuPct: Number((((after.cpuSeconds - before.cpuSeconds) / elapsed) * 100).toFixed(2)),
    windowServerCpuPct: Number(
      (((after.windowServerCpuSeconds - before.windowServerCpuSeconds) / elapsed) * 100).toFixed(2),
    ),
    rssMb: after.rssMb,
    byType,
  };
};

const rendererEval = (code) => panel.webContents.executeJavaScript(code, true);

const condition = async (name, setup, intervals) => {
  await setup();
  await sleep(3_000);
  await rendererEval("window.spike.resetStats()");
  const heapBefore = await rendererEval("performance.memory.usedJSHeapSize");
  const samples = [];
  for (let i = 0; i < intervals; i += 1) samples.push(await sampleInterval(SAMPLE_MS));
  const heapAfter = await rendererEval("performance.memory.usedJSHeapSize");
  const frames = await rendererEval("window.spike.stats()");
  const minutes = (intervals * SAMPLE_MS) / 60_000;
  const mean = (key) =>
    Number((samples.reduce((sum, s) => sum + s[key], 0) / samples.length).toFixed(2));
  return {
    condition: name,
    intervals,
    electronCpuPct: mean("electronCpuPct"),
    psCpuPct: mean("psCpuPct"),
    windowServerCpuPct: mean("windowServerCpuPct"),
    rssMb: samples[samples.length - 1].rssMb,
    byType: samples[samples.length - 1].byType,
    rendererHeapMb: Number((heapAfter / 1048576).toFixed(1)),
    heapGrowthKbPerMin: Math.round((heapAfter - heapBefore) / 1024 / minutes),
    frames,
  };
};

/** The panel as the screen shows it (points; the primary display here is 1x). */
const capturePanel = async () => {
  await sleep(1_500);
  const info = { bounds: panel.getBounds(), visible: panel.isVisible(), tray: trayBounds() };
  const shot = path.join(scratch, "panel.png");
  const b = info.bounds;
  try {
    childProcess.execFileSync("screencapture", ["-x", "-R", `${b.x - 20},${b.y - 30},${b.width + 40},${b.height + 50}`, shot]);
    info.screenshot = shot;
  } catch (error) {
    info.screenshotError = String(error);
  }
  return info;
};

const measure = async () => {
  const report = {
    electron: process.versions.electron,
    chrome: process.versions.chrome,
    node: process.versions.node,
    macOS: os.release(),
    arch: process.arch,
    cores: os.cpus().length,
    note: "electronCpuPct is Electron's getAppMetrics (share of all cores); psCpuPct is the ps cputime delta (share of one core), which is what native's perf cpuSeconds reports too",
    window: { width: WIDTH, height: HEIGHT, vibrancy: "popover", type: "panel" },
    conditions: [],
  };
  showPanel();
  report.panel = await capturePanel();
  report.conditions.push(
    await condition("open, countdown, css shimmer + canvas embers", () => rendererEval("window.spike.setEffect('both')"), 4),
    await condition("open, countdown, css shimmer only", () => rendererEval("window.spike.setEffect('css')"), 2),
    await condition("open, countdown, canvas embers only", () => rendererEval("window.spike.setEffect('canvas')"), 2),
    await condition("open, countdown, canvas embers at half rate", () => rendererEval("window.spike.setEffect('canvas30')"), 2),
    await condition("open, countdown, no effect", () => rendererEval("window.spike.setEffect('none')"), 2),
    await condition("hidden, effects on", async () => {
      await rendererEval("window.spike.setEffect('both')");
      hidePanel();
    }, 2),
  );
  const out = path.join(scratch, "report.json");
  fs.writeFileSync(out, JSON.stringify(report, null, 2));
  process.stdout.write(`${JSON.stringify(report)}\n`);
  process.stdout.write(`report: ${out}\n`);
};

app.whenReady().then(async () => {
  if (process.platform === "darwin") app.dock.hide();
  createTray();
  await createPanel();
  if (SHOT) {
    showPanel();
    process.stdout.write(`${JSON.stringify(await capturePanel())}\n`);
    app.quit();
    return;
  }
  if (AUTO) {
    try {
      await measure();
    } catch (error) {
      process.stderr.write(`measure failed: ${error && error.stack ? error.stack : error}\n`);
      process.exitCode = 1;
    }
    app.quit();
  }
});

app.on("window-all-closed", () => {
  // A tray app: closing the panel is not quitting.
});
