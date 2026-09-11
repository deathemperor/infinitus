// @effect-diagnostics globalTimers:off -- The helper deadline runs at a child-process callback boundary outside any Effect fiber.
// @effect-diagnostics nodeBuiltinImport:off -- This macOS platform boundary spawns the Accessibility reader with Node.

import type { DesktopCaptureGestureEvent } from "@t3tools/contracts";
import { MAX_CAPTURE_TEXT_LENGTH } from "@t3tools/contracts/captures";
import * as NodeChildProcess from "node:child_process";

/**
 * The front app's selected text on macOS (#433 slice 2), read once per
 * gesture through the Accessibility API: the frontmost app's focused element
 * and its `AXSelectedText`. A short `osascript` child, so a hung or crashed
 * bridge call cannot take the shell with it; its stdout is one JSON line,
 * the text already cut to the capture cap. The Accessibility grant is the
 * app's own, the one SnapShot's setup asks for; the child inherits it. The
 * text is never logged here or downstream — only its length.
 */

const READ_TIMEOUT_MS = 3_000;

const READER_SCRIPT = `
ObjC.import("ApplicationServices");
ObjC.import("AppKit");
ObjC.bindFunction("AXUIElementCreateApplication", ["id", ["int"]]);
ObjC.bindFunction("AXUIElementCopyAttributeValue", ["int", ["id", "id", "id*"]]);
function attribute(element, name) {
  const out = Ref();
  const status = $.AXUIElementCopyAttributeValue(element, name, out);
  return { status, value: status === 0 ? out[0] : null };
}
function run(argv) {
  const limit = Number(argv[0]);
  if (!$.AXIsProcessTrusted()) return JSON.stringify({ ok: false, reason: "accessibility" });
  const front = $.NSWorkspace.sharedWorkspace.frontmostApplication;
  if (front.isNil()) return JSON.stringify({ ok: false, reason: "no-focus" });
  const app = $.AXUIElementCreateApplication(front.processIdentifier);
  const focused = attribute(app, "AXFocusedUIElement");
  if (focused.status !== 0) return JSON.stringify({ ok: false, reason: "no-focus" });
  const selected = attribute(focused.value, "AXSelectedText");
  if (selected.status !== 0) return JSON.stringify({ ok: false, reason: "unsupported" });
  const text = ObjC.unwrap(selected.value);
  if (typeof text !== "string") return JSON.stringify({ ok: false, reason: "unsupported" });
  return JSON.stringify({ ok: true, text: text.slice(0, limit) });
}`;

const FAILURES = new Set(["accessibility", "no-focus", "unsupported"]);

/** What the helper's stdout means; anything else is the helper failing. */
export function parseSelectedTextOutput(stdout: string): DesktopCaptureGestureEvent {
  try {
    const parsed = JSON.parse(stdout.trim()) as { ok?: unknown; text?: unknown; reason?: unknown };
    if (parsed.ok === true && typeof parsed.text === "string") {
      return parsed.text.trim() === ""
        ? { type: "empty" }
        : { type: "captured", text: parsed.text };
    }
    if (parsed.ok === false && typeof parsed.reason === "string" && FAILURES.has(parsed.reason)) {
      return {
        type: "failed",
        reason: parsed.reason as "accessibility" | "no-focus" | "unsupported",
      };
    }
  } catch {}
  return { type: "failed", reason: "helper" };
}

export function readMacSelectedText(): Promise<DesktopCaptureGestureEvent> {
  return new Promise((resolve) => {
    let child: NodeChildProcess.ChildProcess;
    try {
      child = NodeChildProcess.spawn(
        "/usr/bin/osascript",
        ["-l", "JavaScript", "-e", READER_SCRIPT, String(MAX_CAPTURE_TEXT_LENGTH)],
        { stdio: ["ignore", "pipe", "ignore"] },
      );
    } catch {
      resolve({ type: "failed", reason: "helper" });
      return;
    }
    let settled = false;
    let stdout = "";
    const settle = (event: DesktopCaptureGestureEvent) => {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      resolve(event);
    };
    const deadline = setTimeout(() => {
      child.kill();
      settle({ type: "failed", reason: "timeout" });
    }, READ_TIMEOUT_MS);
    deadline.unref();
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.once("error", () => settle({ type: "failed", reason: "helper" }));
    child.once("close", (code) => {
      settle(code === 0 ? parseSelectedTextOutput(stdout) : { type: "failed", reason: "helper" });
    });
  });
}
