/**
 * Fork visual pass: drives one headless Chrome over CDP against a running
 * web app — pairs, clicks through the first-run wizard, then screenshots each
 * route and prints its page text.
 *
 *   node scripts/fork-visual-pass.mjs --pair-url <url> --out <dir> [/route …]
 *
 *   --base-url <origin>   where routes are opened (default: the pair URL's origin)
 *   --cdp-port <n>        Chrome's remote-debugging port (default 9345)
 *   --profile <dir>       Chrome user-data dir (default: a temp dir, removed on exit)
 *   --settle-ms <n>       wait after a route mounts before the shot (default 15000)
 *   --mount-timeout-ms <n> give up waiting for a route to mount (default 90000; a
 *                         dev server compiling a cold route chunk can take a while)
 *   CHROME_BIN            Chrome binary (default: the macOS Google Chrome path)
 *
 * The pair URL carries the token; it is never printed. Node ≥ 22 (global
 * fetch + WebSocket), no dependencies.
 */
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

const DEFAULT_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const WIZARD_HEADING = /Set up /;
const WIZARD_BUTTON =
  /^(Skip|Skip for now|Do not import projects|Done|Finish|Continue|Get started)/i;
const APP_MOUNTED = ["Toggle Sidebar", "All projects"];
const STALLED_GATE = "Still connecting";
const PAIR_FAILED = ["Invalid pairing token", "Pair with this environment"];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function parseArgs(argv) {
  const options = { routes: [], cdpPort: 9345, settleMs: 15_000, mountTimeoutMs: 90_000 };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const value = argv[++i];
      if (value === undefined) throw new Error(`${arg} needs a value`);
      return value;
    };
    if (arg === "--pair-url") options.pairUrl = next();
    else if (arg === "--out") options.out = next();
    else if (arg === "--base-url") options.baseUrl = next();
    else if (arg === "--cdp-port") options.cdpPort = Number(next());
    else if (arg === "--profile") options.profile = next();
    else if (arg === "--settle-ms") options.settleMs = Number(next());
    else if (arg === "--mount-timeout-ms") options.mountTimeoutMs = Number(next());
    else if (arg.startsWith("/")) options.routes.push(arg);
    else throw new Error(`unknown argument ${arg}`);
  }
  if (!options.pairUrl || !options.out) {
    throw new Error("usage: fork-visual-pass.mjs --pair-url <url> --out <dir> [/route …]");
  }
  options.baseUrl ??= new URL(options.pairUrl).origin;
  return options;
}

async function launchChrome({ cdpPort, profile }) {
  const child = NodeChildProcess.spawn(
    process.env.CHROME_BIN ?? DEFAULT_CHROME,
    [
      "--headless=new",
      `--remote-debugging-port=${cdpPort}`,
      `--user-data-dir=${profile}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--window-size=1400,900",
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  // Chrome's last lines of stderr, for the error when the port never opens.
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr = (stderr + chunk).slice(-2000);
  });
  // A cold CI runner can take well over 10 s to bring the port up.
  for (let i = 0; i < 150; i++) {
    if (child.exitCode !== null) {
      throw new Error(`Chrome exited with ${child.exitCode}\n${stderr}`);
    }
    try {
      const list = await (await fetch(`http://127.0.0.1:${cdpPort}/json/list`)).json();
      const page = list.find((target) => target.type === "page");
      if (page) return { child, wsUrl: page.webSocketDebuggerUrl };
    } catch {
      // not listening yet
    }
    await sleep(200);
  }
  child.kill();
  throw new Error(`Chrome did not open its debugging port in 30 s\n${stderr}`);
}

function connect(wsUrl) {
  const ws = new WebSocket(wsUrl);
  const pending = new Map();
  let nextId = 0;
  ws.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  });
  const send = (method, params = {}) =>
    new Promise((resolve) => {
      const id = ++nextId;
      pending.set(id, resolve);
      ws.send(JSON.stringify({ id, method, params }));
    });
  const evaluate = async (expression) =>
    (await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result
      ?.result?.value;
  const ready = new Promise((resolve) => {
    ws.addEventListener("open", resolve, { once: true });
  });
  return { ws, send, evaluate, ready };
}

let options;
try {
  options = parseArgs(process.argv.slice(2));
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(2);
}
NodeFS.mkdirSync(options.out, { recursive: true });
const ownsProfile = options.profile === undefined;
const profile =
  options.profile ?? NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "fork-visual-pass-"));
const chrome = await launchChrome({ cdpPort: options.cdpPort, profile });
/** Chrome must be gone before its profile dir goes, or rm races its shutdown. */
const shutdown = async () => {
  const exited = new Promise((resolve) => {
    chrome.child.once("exit", resolve);
    setTimeout(resolve, 5000);
  });
  chrome.child.kill();
  await exited;
  if (ownsProfile) NodeFS.rmSync(profile, { recursive: true, force: true, maxRetries: 3 });
};
process.on("SIGINT", () => void shutdown().then(() => process.exit(130)));
// An uncaught error still takes Chrome down (the temp profile is left for inspection).
process.on("exit", () => chrome.child.kill());

const { ws, send, evaluate, ready } = connect(chrome.wsUrl);
await ready;
await send("Page.enable");
await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", {
  width: 1400,
  height: 900,
  deviceScaleFactor: 1,
  mobile: false,
});

const pageText = async () =>
  ((await evaluate("document.body.innerText")) ?? "").replace(/\s+/g, " ");

/** Until the app tree is mounted; reloads on the stalled connection gate. */
const waitForApp = async (label) => {
  const deadline = Date.now() + options.mountTimeoutMs;
  while (Date.now() < deadline) {
    const text = await pageText();
    if (text.includes(STALLED_GATE)) {
      await evaluate("location.reload()");
      await sleep(4000);
      continue;
    }
    if (APP_MOUNTED.some((marker) => text.includes(marker))) return text;
    await sleep(1500);
  }
  console.warn(`${label}: app not mounted after ${options.mountTimeoutMs} ms (boot shell?)`);
  return await pageText();
};

const clickWizardButton = () =>
  evaluate(`(() => {
    const button = [...document.querySelectorAll("button")].find(
      (b) => ${WIZARD_BUTTON.toString()}.test(b.innerText.trim()) && !b.disabled,
    );
    if (!button) return null;
    button.click();
    return button.innerText.trim();
  })()`);

await send("Page.navigate", { url: options.pairUrl });
const afterPair = await waitForApp("pair");
if (PAIR_FAILED.some((marker) => afterPair.includes(marker))) {
  console.error(
    "pairing failed (tokens are single-use and expire; mint a fresh one):",
    afterPair.slice(0, 200),
  );
  await shutdown();
  process.exit(1);
}
console.log(`paired with ${options.baseUrl}:`, afterPair.slice(0, 120));

for (let i = 0; i < 12 && !WIZARD_HEADING.test(await pageText()); i++) await sleep(1500);
for (let i = 0; i < 10 && WIZARD_HEADING.test(await pageText()); i++) {
  const clicked = await clickWizardButton();
  console.log("wizard click:", clicked);
  if (!clicked) {
    console.log(
      "buttons:",
      await evaluate(
        `[...document.querySelectorAll("button")].map((b) => b.innerText.trim()).filter(Boolean).join(" | ")`,
      ),
    );
    break;
  }
  await sleep(3500);
}
console.log("after wizard:", (await pageText()).slice(0, 160));

for (const route of options.routes) {
  await send("Page.navigate", { url: `${options.baseUrl}${route}` });
  await waitForApp(route);
  await sleep(options.settleMs);
  const shot = await send("Page.captureScreenshot", { format: "png" });
  const name = route.replace(/^\//, "").replace(/\//g, "-") || "home";
  const text = await pageText();
  NodeFS.writeFileSync(
    NodePath.join(options.out, `shot-${name}.png`),
    Buffer.from(shot.result.data, "base64"),
  );
  NodeFS.writeFileSync(NodePath.join(options.out, `text-${name}.txt`), text);
  console.log(`${route}:`, text.slice(0, 400));
}

ws.close();
await shutdown();
process.exit(0);
